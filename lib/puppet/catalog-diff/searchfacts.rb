require 'puppet/network/http_pool'
require 'uri'
require 'json'
require File.expand_path(File.join(File.dirname(__FILE__), 'tlsfactory.rb'))

# Puppet::CatalogDiff
module Puppet::CatalogDiff
  # SearchFacts returns facts from local data, Puppet API, or PuppetDB
  class SearchFacts
    def initialize(facts)
      @facts = facts.split(',').map { |f| f.split('=') }.to_h
    end

    def find_nodes(options = {})
      # Pull all nodes from PuppetDB
      old_env = options[:old_server].split('/')[1]
      Puppet.debug('Using PuppetDB to find active nodes')
      filter_env = options[:filter_old_env] ? old_env : nil
      active_nodes = find_nodes_puppetdb(filter_env, options[:puppetdb], options[:puppetdb_tls_cert], options[:puppetdb_tls_key], options[:puppetdb_tls_ca])
      raise 'No active nodes were returned from your fact search' if active_nodes.empty?

      active_nodes
    end

    def build_query(env, version)
      base_query = ['and', ['=', %w[node active], true]]
      query_field_catalog_environment = Puppet::Util::Package.versioncmp(version, '3') >= 0 ? 'catalog_environment' : 'catalog-environment'
      base_query.concat([['=', query_field_catalog_environment, env]]) if env
      real_facts = @facts.compact
      query = base_query.concat(real_facts.map { |k, v| ['=', ['fact', k], v] })
      classes = @facts.select { |_k, v| v.nil? }.to_h.keys
      classes.each do |c|
        capit = c.split('::').map(&:capitalize).join('::')
        query.concat(
          [['in', 'certname',
            ['extract', 'certname',
             ['select-resources',
              ['and',
               ['=', 'type', 'Class'],
               ['=', 'title', capit]]]]]]
        )
      end
      query
    end

    def get_puppetdb_version(server, puppetdb_tls_cert, puppetdb_tls_key, puppetdb_tls_ca)
      headers = { 'Accept' => 'application/json' }
      ssl_context = Puppet::CatalogDiff::Tlsfactory.ssl_context(puppetdb_tls_cert, puppetdb_tls_key, puppetdb_tls_ca)
      Puppet.debug("connecting to #{server}")
      uri = URI("#{server}/pdb/meta/v1/version")
      result = Puppet.runtime[:http].get(uri, headers: headers, options: { ssl_context: ssl_context })
      if result.code == 200
        body = JSON.parse(result.body)
        version = body['version']
        Puppet.debug("Got PuppetDB version: #{version} from HTTP API.")
      else
        version = '2.3'
        Puppet.debug("Getting PuppetDB version failed because HTTP API query returned code #{result.code}. Falling back to PuppetDB version #{version}.")
      end
      version
    end

    def find_nodes_puppetdb(env, puppetdb, puppetdb_tls_cert, puppetdb_tls_key, puppetdb_tls_ca)
      puppetdb_version = get_puppetdb_version(puppetdb, puppetdb_tls_cert, puppetdb_tls_key, puppetdb_tls_ca)
      query = build_query(env, puppetdb_version)
      json_query = URI.encode_www_form_component(query.to_json)
      headers = { 'Accept' => 'application/json' }
      Puppet.debug("Querying #{puppetdb} for environment #{env}")
      begin
        ssl_context = Puppet::CatalogDiff::Tlsfactory.ssl_context(puppetdb_tls_cert, puppetdb_tls_key, puppetdb_tls_ca)
        uri = URI("#{puppetdb}/pdb/query/v4/nodes?query=#{json_query}")
        result = Puppet.runtime[:http].get(uri, headers: headers, options: { ssl_context: ssl_context })
        if result.code >= 400
          puppetdb_version = '2.3'
          Puppet.debug("Query returned HTTP code #{result.code}. Falling back to older version of API used in PuppetDB version #{puppetdb_version}.")
          query = build_query(env, puppetdb_version)
          json_query = URI.encode_www_form_component(query.to_json)
          result = Puppet.runtime[:http].get(URI("#{puppetdb}/pdb/query/v4/nodes?query=#{json_query}"), headers: headers)
        end
        filtered = JSON.parse(result.body)
      rescue JSON::ParserError => e
        raise "Error parsing json output of puppet search: #{e.message}"
      end
      filtered.map { |node| node['certname'] }
    end
  end
end
