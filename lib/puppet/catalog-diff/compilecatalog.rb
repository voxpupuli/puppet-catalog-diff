require 'puppet/network/http_pool'
require File.expand_path(File.join(File.dirname(__FILE__), 'preprocessor.rb'))
require File.expand_path(File.join(File.dirname(__FILE__), 'tlsfactory.rb'))

# Puppet::CatalogDiff
module Puppet::CatalogDiff
  # Puppet::CatalogDiff::CompileCatalog
  # allows to retrieve a catalog, using
  # v3/catalog, v4/catalog or PuppetDB
  class CompileCatalog
    include Puppet::CatalogDiff::Preprocessor

    attr_reader :node_name

    def initialize(node_name, save_directory, server, certless, catalog_from_puppetdb, puppetdb, puppetdb_tls_cert, puppetdb_tls_key, puppetdb_tls_ca, puppetserver_tls_cert, puppetserver_tls_key, puppetserver_tls_ca, derive_trusted_facts)
      @node_name = node_name
      catalog = if catalog_from_puppetdb
                  get_catalog_from_puppetdb(node_name, server, puppetdb, puppetdb_tls_cert, puppetdb_tls_key, puppetdb_tls_ca)
                else
                  catalog = compile_catalog(node_name, server, certless, puppetserver_tls_cert, puppetserver_tls_key, puppetserver_tls_ca, derive_trusted_facts)
                  clean_sensitive_parameters!(catalog)
                  clean_nested_sensitive_parameters!(catalog)
                  catalog
                end
      catalog = render_json(catalog)
      begin
        save_catalog_to_disk(save_directory, node_name, catalog, 'json')
      rescue Exception => e
        Puppet.err("Server returned invalid catalog for #{node_name}")
        save_catalog_to_disk(save_directory, node_name, catalog, 'error')
        raise e.message if catalog =~ %r{.document_type.:.Catalog.}

        raise catalog
      end
    end

    def lookup_environment(node_name)
      # Compile the catalog with the last environment used according to the yaml terminus
      # The following is a hack as I can't pass :mode => master in the 2.7 series
      node = Puppet::Face[:node, '0.0.1'].find(node_name, terminus: 'yaml')
      raise "Error retrieving node object from yaml terminus #{node_name}" unless node

      Puppet.debug("Found environment #{node.environment} for node #{node_name}")
      raise "The node retrieved from yaml terminus is a mismatch node returned was (#{node.parameters['clientcert']})" if node.parameters['clientcert'] != node_name

      node.environment
    end

    def get_catalog_from_puppetdb(node_name, server, puppetdb, puppetdb_tls_cert, puppetdb_tls_key, puppetdb_tls_ca)
      Puppet.debug("Getting PuppetDB catalog for #{node_name} from #{puppetdb}")
      query = ['and', ['=', 'certname', node_name.to_s]]
      _server, environment = server.split('/')
      environment ||= lookup_environment(node_name)
      query.concat([['=', 'environment', environment]])
      json_query = URI.encode_www_form_component(query.to_json)
      request_url = URI("#{puppetdb}/pdb/query/v4/catalogs?query=#{json_query}")
      headers = { 'Accept-Content' => 'application/json' }
      ssl_context = Puppet::CatalogDiff::Tlsfactory.ssl_context(puppetdb_tls_cert, puppetdb_tls_key, puppetdb_tls_ca)
      ret = Puppet.runtime[:http].get(request_url, headers: headers, options: { ssl_context: ssl_context })
      raise "HTTP request to PuppetDB failed with: HTTP #{ret.code} - #{ret.reason}" unless ret.success?

      begin
        catalog = JSON.parse(ret.body)
      rescue JSON::ParserError => e
        raise "Error parsing json output of puppetdb catalog query for #{node_name}: #{e.message}\ncontent: #{ret.body}"
      end

      convert_pdb(catalog)
    end

    def compile_catalog(node_name, server, certless, tls_cert, tls_key, tls_ca, derive_trusted_facts)
      Puppet.debug("Compiling catalog for #{node_name}")
      server, environment = server.split('/')
      environment ||= lookup_environment(node_name)
      server, port = server.split(':')
      port ||= '8140'
      headers = {
        'Accept' => 'application/json',
      }

      if certless
        endpoint = '/puppet/v4/catalog'
        headers['Content-Type'] = 'text/json'
        body = {
          certname: node_name,
          environment: environment,
          persistence: {
            facts: false,
            catalog: false,
          },
          options: {
            prefer_requested_environment: true,
          },
        }
        if derive_trusted_facts
          body['trusted_facts'] = {
            values: {
              domain: node_name.split('.')[1..],
              certname: node_name,
              external: {},
              hostname: node_name.split('.')[0],
              extensions: {},
              authenticated: 'remote',
            },
          }
        end
      else
        endpoint = "/puppet/v3/catalog/#{node_name}?environment=#{environment}"
      end

      uri = URI("https://#{server}:#{port}#{endpoint}")
      ssl_context = Puppet::CatalogDiff::Tlsfactory.ssl_context(tls_cert, tls_key, tls_ca)
      begin
        ret = if certless
                Puppet.runtime[:http].post(uri, body.to_json, headers: headers, options: { ssl_context: ssl_context })
              else
                Puppet.runtime[:http].get(uri, headers: headers, options: { ssl_context: ssl_context })
              end
        raise "HTTP request to Puppetserver #{server} failed with: HTTP #{ret.code} - #{ret.body}" unless ret.success?
      rescue Exception => e
        raise "Failed to retrieve catalog for #{node_name} from #{server} in environment #{environment}: #{e.message}"
      end

      begin
        catalog = JSON.parse(ret.body)
      rescue JSON::ParserError => e
        raise "Error parsing json output of puppet catalog query for #{node_name}: #{e.message}. Content: #{ret.body}"
      end
      raise catalog['message'] if catalog.key?('issue_kind')

      catalog = catalog['catalog'] if certless
      catalog
    end

    def render_json(catalog)
      json = JSON.pretty_generate(catalog, allow_nan: true, max_nesting: false)
      raise "Could not render catalog as json, #{catalog}" unless json

      json
    end

    def clean_sensitive_parameters!(catalog)
      catalog['resources'].map! do |resource|
        if resource.key? 'sensitive_parameters'
          resource['sensitive_parameters'].each do |p|
            hash = Digest::SHA256.hexdigest Marshal.dump(resource['parameters'][p])
            resource['parameters'][p] = "Sensitive [hash #{hash}]"
          end
          resource.delete('sensitive_parameters')
        end
        resource
      end
    end

    def clean_nested_sensitive_parameters!(catalog)
      # Resources can also contain sensitive data nested deep in hashes/arrays
      catalog['resources'].each do |resource|
        redact_sensitive(resource['parameters']) if resource.key? 'parameters'
      end
    end

    def redact_sensitive(data)
      if data.is_a?(Hash) && data.key?('__ptype')
        data[:catalog_diff_hash] = Digest::SHA256.hexdigest Marshal.dump(data['__pvalue'])
        data.reject! { |k| %w[__ptype __pvalue].include?(k) }
      elsif data.is_a? Hash
        data.each do |_k, v|
          redact_sensitive(v) if v.is_a?(Hash) || v.is_a?(Array)
        end
      elsif data.is_a? Array
        data.each do |v|
          redact_sensitive(v) if v.is_a?(Hash) || v.is_a?(Array)
        end
      end
    end

    def save_catalog_to_disk(save_directory, node_name, catalog, extention)
      Puppet.debug("Saving catalog for #{node_name} to: #{save_directory}/#{node_name}.#{extention}")
      File.write("#{save_directory}/#{node_name}.#{extention}", catalog)
    rescue Exception => e
      raise "Failed to save catalog for #{node_name} in #{save_directory}: #{e.message}"
    end
  end
end
