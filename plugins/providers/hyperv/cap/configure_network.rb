require "log4r"
require "fileutils"
require "vagrant/util/numeric"
require "vagrant/util/experimental"

module VagrantPlugins
  module HyperV
    module Cap
      module ConfigureNetwork
        LOGGER = Log4r::Logger.new("vagrant::plugins::hyperv::configure_network")

        # Reads the network interface card MAC addresses and returns them.
        #
        # @return [Hash<String, String>] Adapter => MAC address
        def self.nic_mac_addresses(machine)
            machine.provider.driver.read_mac_addresses
        end
      end
    end
  end
end