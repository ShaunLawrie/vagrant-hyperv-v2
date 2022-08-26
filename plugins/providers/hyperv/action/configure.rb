require "fileutils"

require "log4r"
require "timeout"
require "vagrant/util/network_ip"

module VagrantPlugins
  module HyperV
    module Action
      class Configure

        include Vagrant::Util::NetworkIP

        def initialize(app, env)
          @app = app
          @logger = Log4r::Logger.new("vagrant::hyperv::configure")
        end

        def call(env)
          @env = env
          env[:machine].provider.driver.execute(:install_managed_switches)
          managed_switches = env[:machine].provider.driver.execute(:get_managed_switches)
          switches = env[:machine].provider.driver.execute(:get_switches)
          if switches.empty?
            raise Errors::NoSwitches
          end

          # Use the hyper-v Default Switch for NAT if a bridged switch wasn't found
          default_switch = managed_switches.find{ |s|
            s["SwitchType"].downcase == "nat"
          }

          # Attach explicitly defined networks starting at number 2 because 1 is the NAT switch
          additional_switches = []
          networks = []
          adapters = []
          adapterCount = 2
          env[:machine].config.vm.networks.each do |type, opts|
            next if type != :public_network && type != :private_network

            # Internal network is a special type which is shared between guests but not the host
            if type == :private_network && opts[:intnet]
              type = :internal_network
            end

            # Private network is the equivalent of virtualbox host-only network
            # Annoyingly the private/internal terminology is flipped in hyper-v so an internal switch is what we want here
            if type == :private_network
              private_switch = managed_switches.find{ |s|
                s["SwitchType"].downcase == "internal"
              }
              data = [:hostonly, opts]
              additional_switches.append(private_switch["Id"])
            end

            # Again, the hyper-v terminology is flipped. We want a private switch for an internal network
            if type == :internal_network
              internal_switch = managed_switches.find{ |s|
                s["SwitchType"].downcase == "private"
              }
              data = [:intnet, opts]
              additional_switches.push(internal_switch["Id"])
            end

            # Public networks will be bridged to a specified network or prompted if it can't be found
            prompt = false
            if type == :public_network
              if opts[:bridge]
                @logger.debug("Looking for switch with name or ID: #{opts[:bridge]}")
                switch = switches.find{ |s|
                  s["Name"].downcase == opts[:bridge].to_s.downcase ||
                    s["Id"].downcase == opts[:bridge].to_s.downcase
                }
                if switch
                  @logger.debug("Found switch - Name: #{switch["Name"]} ID: #{switch["Id"]}")
                  additional_switches.append(switch["Id"])
                else
                  prompt = true
                end
              else
                # Prompt if bridged interface wasn't specified or wasn't found
                if switches.length > 1
                  if prompt
                    env[:ui].detail(I18n.t("vagrant_hyperv.choose_switch") + "\n ")
                    switches.each_index do |i|
                      switch = switches[i]
                      env[:ui].detail("#{i+1}) #{switch["Name"]}")
                    end
                    env[:ui].detail(" ")
      
                    switch = nil
                    while !switch
                      switch = env[:ui].ask("What switch would you like to use? ")
                      next if !switch
                      switch = switch.to_i - 1
                      switch = nil if switch < 0 || switch >= switches.length
                    end
                    additional_switches.append(switches[switch]["Id"])
                  end
                else
                  raise Errors::NoExternalSwitches
                end
              end
              data = [:bridged, opts]
            end

            ## Logic copied from the virtualbox setup
            type    = data[0]
            options = data[1]

            config = send("#{type}_config", options)
            config[:adapter] = adapterCount
            env[:ui].detail("Normalized configuration: #{config.inspect}")

            adapter = send("#{type}_adapter", config)
            adapters << adapter
            env[:ui].detail("Adapter configuration: #{adapter.inspect}")

            network = send("#{type}_network_config", config)
            env[:ui].detail("Network configuration: #{network.inspect}")
            network[:auto_config] = config[:auto_config]
            networks << network

            adapterCount = adapterCount + 1
          end

          default_switch_id = default_switch["Id"]

          options = {
            "VMID" => env[:machine].id,
            "SwitchID" => default_switch["Id"],
            "Memory" => env[:machine].provider_config.memory,
            "MaxMemory" => env[:machine].provider_config.maxmemory,
            "Processors" => env[:machine].provider_config.cpus,
            "AutoStartAction" => env[:machine].provider_config.auto_start_action,
            "AutoStopAction" => env[:machine].provider_config.auto_stop_action,
            "EnableCheckpoints" => env[:machine].provider_config.enable_checkpoints,
            "EnableAutomaticCheckpoints" => env[:machine].provider_config.enable_automatic_checkpoints,
            "VirtualizationExtensions" => !!env[:machine].provider_config.enable_virtualization_extensions,
            "AdditionalSwitches" => additional_switches.join(",")
          }
          options.delete_if{|_,v| v.nil? }
          env[:machine].provider.driver.execute(:configure_vm, options)

          if !env[:machine].provider_config.vm_integration_services.empty?
            env[:machine].provider_config.vm_integration_services.each do |key, value|
              state = value ? "enabled" : "disabled"
              env[:ui].output("#{key} is #{state}")
            end

            env[:machine].provider.driver.set_vm_integration_services(
              env[:machine].provider_config.vm_integration_services)
          end

          if env[:machine].provider_config.enable_enhanced_session_mode
            env[:machine].provider.driver.set_enhanced_session_transport_type("HvSocket")
          else
            env[:machine].provider.driver.set_enhanced_session_transport_type("VMBus")
          end
          
          # Continue the middleware chain.
          @app.call(env)

          # If we have networks to configure, then we configure it now, since
          # that requires the machine to be up and running.
          if !adapters.empty? && !networks.empty?
            assign_interface_numbers(networks, adapters)

            # Only configure the networks the user requested us to configure
            networks_to_configure = networks.select { |n| n[:auto_config] }
            if !networks_to_configure.empty?
              env[:ui].info I18n.t("vagrant.actions.vm.network.configuring")
              # Hyper-v is aggressive with dhcp renewal and when the VM runs `netplan apply` it might get
              # a new IP address and break the SSH connection which will hang forever
              begin
                Timeout.timeout(60) do
                  env[:machine].guest.capability(:configure_networks, networks_to_configure)
                end
              rescue Timeout::Error
                env[:ui].detail("Timed out waiting for network configuration to apply but it's probably all good")
              end
            end
          end
        end

        def hostonly_adapter(config)
          @logger.info("Searching for matching hostonly network: #{config[:ip]}")
          interface = hostonly_find_matching_network(config)

          if config[:type] == :dhcp
            create_dhcp_server_if_necessary(interface, config)
          end

          return {
            adapter:     config[:adapter],
            hostonly:    interface[:name],
            mac_address: config[:mac],
            nic_type:    config[:nic_type],
            type:        :hostonly
          }
        end

        def hostonly_config(options)
          options = {
            auto_config: true,
            mac:         nil,
            nic_type:    nil,
            type:        :static,
          }.merge(options)

          # Make sure the type is a symbol
          options[:type] = options[:type].to_sym

          if options[:type] == :dhcp && !options[:ip]
            # Try to find a matching device to set the config ip to
            matching_device = hostonly_find_matching_network(options)
            if matching_device
              options[:ip] = matching_device[:ip]
            else
              # Default IP is in the 20-bit private network block for DHCP based networks
              options[:ip] = "192.168.56.1"
            end
          end

          begin
            ip = IPAddr.new(options[:ip])
            if ip.ipv4?
              options[:netmask] ||= "255.255.255.0"
            elsif ip.ipv6?
              options[:netmask] ||= 64

              # Append a 6 to the end of the type
              options[:type] = "#{options[:type]}6".to_sym
            else
              raise IPAddr::AddressFamilyError, 'unknown address family'
            end

            # Calculate our network address for the given IP/netmask
            netaddr = IPAddr.new("#{options[:ip]}/#{options[:netmask]}")
          rescue IPAddr::Error => e
            raise Vagrant::Errors::NetworkAddressInvalid,
              address: options[:ip], mask: options[:netmask],
              error: e.message
          end

          validate_hostonly_ip!(options[:ip], @env[:machine].provider.driver)

          # Calculate the adapter IP which is the network address with
          # the final bit + 1. Usually it is "x.x.x.1" for IPv4 and
          # "<prefix>::1" for IPv6
          options[:adapter_ip] ||= (netaddr | 1).to_s

          dhcp_options = {}
          if options[:type] == :dhcp
            # Calculate the DHCP server IP and lower & upper bound
            # Example: for "192.168.22.64/26" network range those are:
            # dhcp_ip: "192.168.22.66",
            # dhcp_lower: "192.168.22.67"
            # dhcp_upper: "192.168.22.126"
            ip_range = netaddr.to_range
            dhcp_options[:dhcp_ip] = options[:dhcp_ip] || (ip_range.first | 2).to_s
            dhcp_options[:dhcp_lower] = options[:dhcp_lower] || (ip_range.first | 3).to_s
            dhcp_options[:dhcp_upper] = options[:dhcp_upper] || (ip_range.last(2).first).to_s
          end

          return {
            adapter_ip:  options[:adapter_ip],
            auto_config: options[:auto_config],
            ip:          options[:ip],
            mac:         options[:mac],
            name:        options[:name],
            netmask:     options[:netmask],
            nic_type:    options[:nic_type],
            type:        options[:type]
          }.merge(dhcp_options)
        end

        # This finds a matching host only network for the given configuration.
        def hostonly_find_matching_network(config)
          # Always returns the same network atm
          interface = @env[:machine].provider.driver.read_host_only_interface
          return {
            name: interface["Name"].to_s,
            ip: interface["IP"].to_s,
            netmask: interface["Netmask"].to_s,
            ipv6: interface["IPv6"].to_s.strip,
            ipv6_prefix: interface["IPv6Prefix"].to_s.strip,
            status: interface["Status"].to_s
          }
        end

        def create_dhcp_server_if_necessary(interface, config)
          raise Errors::DhcpNotSupported
        end

        # Validates the IP used to configure the network is within the allowed
        # ranges. Allowed will be any IP not currently in use by a physical adaptor
        def validate_hostonly_ip!(ip, driver)
          ip = IPAddr.new(ip.to_s) if !ip.is_a?(IPAddr)
          invalid_ranges = load_net_conf
          if invalid_ranges.any?{ |range| range.include?(ip) }
            raise Vagrant::Errors::VirtualBoxInvalidHostSubnet,
              address: ip,
              ranges_in_use: invalid_ranges.map{ |r| "#{r}/#{r.prefix}" }.join(", ")
          end
        end

        # Load all the current networks on the machine to make sure we're not colliding with something in use
        def load_net_conf
          net_conf = []
          host_network_config = @env[:machine].provider.driver.execute(:get_hyperv_host_network_conf)
          host_network_config.each do |net|
            net_conf.append(IPAddr.new(net))
          end
          return net_conf
        end

        def hostonly_network_config(config)
          return {
            type:       config[:type],
            adapter_ip: config[:adapter_ip],
            ip:         config[:ip],
            netmask:    config[:netmask]
          }
        end

        def assign_interface_numbers(networks, adapters)
          current = 0
          adapter_to_interface = {}

          # Make a first pass to assign interface numbers by adapter location
          vm_adapters = read_network_interfaces
          vm_adapters.sort.each do |number, adapter|
            if adapter[:type] != :none
              # Not used, so assign the interface number and increment
              adapter_to_interface[number] = current
              current += 1
            end
          end

          # Make a pass through the adapters to assign the :interface
          # key to each network configuration.
          adapters.each_index do |i|
            adapter = adapters[i]
            network = networks[i]

            # Figure out the interface number by simple lookup
            network[:interface] = adapter_to_interface[adapter[:adapter]]
          end
        end

        def read_network_interfaces
          nics = {}
          vm_network_adapters = @env[:machine].provider.driver.execute(:get_vm_network_adapters, VmId: @env[:machine].id)
          vm_network_adapters.each do |interface|
            adapter = interface["Number"].to_i
            type    = interface["Type"].to_sym
            network = interface["Network"].to_s

            nics[adapter] = {}
            nics[adapter][:type] = type

            if type == :hostonly
              nics[adapter][:hostonly] = network
            elsif type == :bridge
              nics[adapter][:bridge] = network
            end
          end
          return nics
        end
      end
    end
  end
end
