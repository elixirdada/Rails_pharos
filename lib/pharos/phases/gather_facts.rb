# frozen_string_literal: true

require 'ipaddr'

module Pharos
  module Phases
    class GatherFacts < Pharos::Phase
      title "Gather host facts"

      FULL_HOSTNAME_CLOUD_PROVIDERS = %w(aws vsphere).freeze

      def call
        Thread.current.abort_on_exception = true
        logger.info { "Checking sudo access ..." }
        check_sudo
        logger.info { "Gathering host facts ..." }
        gather_host_facts
      end

      def check_sudo
        transport.exec!('sudo -n true')
      rescue Pharos::ExecError => exc
        raise Pharos::InvalidHostError, "Unable to sudo: #{exc.output}"
      end

      def gather_host_facts
        @host.os_release = os_release
        @host.cpu_arch = cpu_arch
        @host.hostname = hostname
        @host.checks.replace(host_checks)
        @host.private_interface_address = private_interface_address(@host.private_interface) if @host.private_interface
        @host.resolvconf = read_resolvconf
        @host.routes = read_routes
      end

      # @return [String]
      def hostname
        cloud_provider = @config.cloud&.provider
        if FULL_HOSTNAME_CLOUD_PROVIDERS.include?(cloud_provider)
          transport.exec!('hostname -f').strip
        else
          transport.exec!('hostname -s').strip
        end.downcase
      end

      # @return [Pharos::Configuration::OsRelease]
      def os_release
        raise Pharos::InvalidHostError, "Only linux hosts supported" unless transport.exec?('uname | grep -q -i linux')

        os_info = {}
        transport.file('/etc/os-release').each_line do |line|
          match = line.match(/^(.+)=(.+)$/)
          os_info[match[1]] = match[2].delete('"') if match
        end
        Pharos::Configuration::OsRelease.new(
          id: os_info['ID'],
          id_like: os_info['ID_LIKE'] || os_info['ID'],
          name: os_info['PRETTY_NAME'],
          version: os_info['VERSION_ID']
        )
      end

      # @return [Pharos::Configuration::CpuArch]
      def cpu_arch
        arch = transport.exec!('uname -m')
        Pharos::Configuration::CpuArch.new(
          id: arch.strip
        )
      end

      # @return [Hash]
      def host_checks
        data = {}
        data['kubelet_configured'] = transport.file('/etc/kubernetes/kubelet.conf').exist?
        data['ca_exists'] = transport.file('/etc/kubernetes/pki/ca.key').exist?
        data['etcd_ca_exists'] = transport.file('/etc/pharos/pki/ca-key.pem').exist?

        if data['ca_exists']
          result = transport.exec("sudo curl -sSf --connect-timeout 1 --cacert /etc/kubernetes/pki/ca.crt https://localhost:6443/healthz")
          data['api_healthy'] = (result.success? && result.stdout == 'ok')
        end

        if data['etcd_ca_exists']
          etcd = Pharos::Etcd::Client.new(host.transport)
          data['etcd_healthy'] = etcd.healthy?
        end

        data
      end

      # @param interface [String]
      # @return [String]
      def private_interface_address(interface)
        transport.exec!("ip -o addr show dev #{interface} scope global").each_line do |line|
          _index, _dev, _family, addr = line.split
          ip, _prefixlen = addr.split('/')

          next if ip == @host.address

          return ip
        end
        nil
      end

      # @return [Array<String>]
      def resolvconf_nameservers
        @resolvconf_nameservers ||= transport.file('/etc/resolv.conf').lines.map { |l| l[/^nameserver ([\h:.]+)/, 1] }.compact
      end

      # @return [Boolean]
      def resolvconf_nameserver_localhost?
        resolvconf_nameservers.any? { |ip| IPAddr.new(ip).loopback? }
      end

      # Host /etc/resolv.conf is configured to use the systemd-resolved stub resolver at 127.0.0.53
      # @return [Boolean]
      def resolvconf_systemd_resolved_stub?
        !!transport.file('/etc/resolv.conf').readlink && resolvconf_nameservers.include?('127.0.0.53')
      end

      # @return [Pharos::Configuration::ResolvConf]
      def read_resolvconf
        Pharos::Configuration::ResolvConf.new(
          nameserver_localhost: resolvconf_nameserver_localhost?,
          systemd_resolved_stub: resolvconf_systemd_resolved_stub?
        )
      end

      # @return [Array<Pharos::Configuration::Route>]
      def read_routes
        [].tap do |routes|
          transport.exec!("sudo ip route").each_line do |line|
            routes << Pharos::Configuration::Route.parse(line)
          rescue RuntimeError => exc
            logger.warn { exc }
          end
        end
      end
    end
  end
end
