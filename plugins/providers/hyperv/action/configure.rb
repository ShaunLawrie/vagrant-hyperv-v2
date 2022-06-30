require "fileutils"

require "log4r"

require "vagrant/util/network_ip"

module VagrantPlugins
  module HyperV
    module Action
      class Configure

        # Location of the VirtualBox networks configuration file
        VBOX_NET_CONF = "/etc/vbox/networks.conf".freeze

        # Default valid range for hostonly networks
        HOSTONLY_DEFAULT_RANGE = [IPAddr.new("192.168.57.0/21").freeze].freeze

        include Vagrant::Util::NetworkIP

        def initialize(app, env)
          @app = app
          @logger = Log4r::Logger.new("vagrant::hyperv::configure")
        end

        def call(env)
          @env = env
          managed_switches = env[:machine].provider.driver.execute(:get_managed_switches)
          switches = env[:machine].provider.driver.execute(:get_switches)
          if switches.empty?
            raise Errors::NoSwitches
          end

          # Use the hyper-v Default Switch for NAT if a bridged switch wasn't found
          default_switch = managed_switches.find{ |s|
            s["SwitchType"].downcase == "nat"
          }

          # Attach explicitly defined networks
          additional_switches = []
          networks = []
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
                  next
                end
              end
              # Prompt if bridged interface wasn't specified or wasn't found
              if external_switches.length > 1
                env[:ui].detail(I18n.t("vagrant_hyperv.choose_switch") + "\n ")
                external_switches.each_index do |i|
                  switch = external_switches[i]
                  env[:ui].detail("#{i+1}) #{switch["Name"]}")
                end
                env[:ui].detail(" ")
  
                switch = nil
                while !switch
                  switch = env[:ui].ask("What switch would you like to use? ")
                  next if !switch
                  switch = switch.to_i - 1
                  switch = nil if switch < 0 || switch >= external_switches.length
                end
                additional_switches.append(external_switches[switch]["Id"])
              else
                raise Errors::NoExternalSwitches
              end
              data = [:bridged, opts]
            end

            ##
            ## NEED SMARTS. COPY VBOX BULLSHIT
            ##

            type    = data[0]
            options = data[1]
            env[:ui].detail("#{data[0]} #{data[1]}")
            config = send("#{type}_config", options)
            env[:ui].detail("Normalized configuration: #{config.inspect}")

            # Get the network configuration
            env[:ui].detail("#{data[0]} #{data[1]}")
            network = send("#{type}_network_config", config)
            network[:auto_config] = config[:auto_config]
            networks << network
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

          env[:ui].detail("Configuring the VM...")
          env[:machine].provider.driver.execute(:configure_vm, options)

          if !env[:machine].provider_config.vm_integration_services.empty?
            env[:ui].detail("Setting VM Integration Services")

            env[:machine].provider_config.vm_integration_services.each do |key, value|
              state = value ? "enabled" : "disabled"
              env[:ui].output("#{key} is #{state}")
            end

            env[:machine].provider.driver.set_vm_integration_services(
              env[:machine].provider_config.vm_integration_services)
          end

          if env[:machine].provider_config.enable_enhanced_session_mode
            env[:ui].detail(I18n.t("vagrant.hyperv_enable_enhanced_session"))
            env[:machine].provider.driver.set_enhanced_session_transport_type("HvSocket")
          else
            env[:ui].detail(I18n.t("vagrant.hyperv_disable_enhanced_session"))
            env[:machine].provider.driver.set_enhanced_session_transport_type("VMBus")
          end

          @app.call(env)
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

          ip = options[:ip]
          driver = @env[:machine].provider.driver
          validate_hostonly_ip!(ip, driver)

          if ip.ipv4?
            # Verify that a host-only network subnet would not collide
            # with a bridged networking interface.
            #
            # If the subnets overlap in any way then the host only network
            # will not work because the routing tables will force the
            # traffic onto the real interface rather than the VirtualBox
            # interface.
            @env[:machine].provider.driver.read_bridged_interfaces.each do |interface|
              that_netaddr = network_address(interface[:ip], interface[:netmask])
              if netaddr == that_netaddr && interface[:status] != "Down"
                raise Vagrant::Errors::NetworkCollision,
                  netaddr: netaddr,
                  that_netaddr: that_netaddr,
                  interface_name: interface[:name]
              end
            end
          end

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
          this_netaddr = network_address(config[:ip], config[:netmask])  if config[:ip]

          @env[:machine].provider.driver.read_host_only_interfaces.each do |interface|
            return interface if config[:name] && config[:name] == interface[:name]

            #if a config name is specified, we should only look for that.
            if config[:name].to_s != ""
              next
            end

            if interface[:ip] != ""
              return interface if this_netaddr == \
                network_address(interface[:ip], interface[:netmask])
            end

            if interface[:ipv6] != ""
              return interface if this_netaddr == \
                network_address(interface[:ipv6], interface[:ipv6_prefix])
            end
          end

          nil
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
              ranges: valid_ranges.map{ |r| "#{r}/#{r.prefix}" }.join(", ")
          end
        end

        # Load all the current networks on the machine to make sure we're not colliding with something in use
        def load_net_conf
          net_conf = []
          host_network_config = @env[:machine].provider.driver.execute(:get_hyperv_host_network_conf)
          host_network_config.each do |net|
            net_conf.append(IPAddr.new(net))
          end
        end
      end
    end
  end
end
