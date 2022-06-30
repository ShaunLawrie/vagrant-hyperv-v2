require "fileutils"

require "log4r"

module VagrantPlugins
  module HyperV
    module Action
      class Configure
        def initialize(app, env)
          @app = app
          @logger = Log4r::Logger.new("vagrant::hyperv::configure")
        end

        def call(env)
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
          additional_switches = Array.new
          env[:machine].config.vm.networks.each do |type, opts|
            next if type != :public_network && type != :private_network

            # Internal network is a special type which is shared between guests but not the host
            if type == :private_network && opts[:intnet]
              type = :internal_network
            end

            # Private network is the equivalent of virtualbox host-only network
            # Annoyingly the private/internal terminology is flipped in hyper-v so an internal switch is what we want here
            if type == :private_network
              env[:ui].detail("Looking for private_network switch")
              switches.each_index do |i|
                switch = switches[i]
                env[:ui].detail("#{i+1}) #{switch["Name"]} / #{switch["SwitchType"]} / #{switch["Id"]}")
              end
              private_switch = switches.find{ |s|
                s["SwitchType"].downcase == "internal"
              }
              additional_switches.append(private_switch["Id"])
            end

            # Again, the hyper-v terminology is flipped. We want a private switch for an internal network
            if type == :internal_network
              internal_switch = switches.find{ |s|
                s["SwitchType"].downcase == "private"
              }
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
            end
          end

          options = {
            "VMID" => env[:machine].id,
            "SwitchID" => default_switch,
            "Memory" => env[:machine].provider_config.memory,
            "MaxMemory" => env[:machine].provider_config.maxmemory,
            "Processors" => env[:machine].provider_config.cpus,
            "AutoStartAction" => env[:machine].provider_config.auto_start_action,
            "AutoStopAction" => env[:machine].provider_config.auto_stop_action,
            "EnableCheckpoints" => env[:machine].provider_config.enable_checkpoints,
            "EnableAutomaticCheckpoints" => env[:machine].provider_config.enable_automatic_checkpoints,
            "VirtualizationExtensions" => !!env[:machine].provider_config.enable_virtualization_extensions,
            "AdditionalSwitches" => additional_switches
          }
          options.delete_if{|_,v| v.nil? }

          env[:ui].detail("Configuring the VM...")
          env[:machine].provider.driver.execute(:configure_vm, options)

          # Create the sentinel
          if !sentinel.file?
            sentinel.open("w") do |f|
              f.write(Time.now.to_i.to_s)
            end
          end

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
      end
    end
  end
end
