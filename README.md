# Puppet Catalog Diff

[![Build Status](https://github.com/voxpupuli/puppet-catalog_diff/workflows/CI/badge.svg)](https://github.com/voxpupuli/puppet-catalog_diff/actions?query=workflow%3ACI)
[![Release](https://github.com/voxpupuli/puppet-catalog_diff/actions/workflows/release.yml/badge.svg)](https://github.com/voxpupuli/puppet-catalog_diff/actions/workflows/release.yml)
[![Puppet Forge](https://img.shields.io/puppetforge/v/puppet/catalog_diff.svg)](https://forge.puppetlabs.com/puppet/catalog_diff)
[![Puppet Forge - downloads](https://img.shields.io/puppetforge/dt/puppet/catalog_diff.svg)](https://forge.puppetlabs.com/puppet/catalog_diff)
[![Puppet Forge - endorsement](https://img.shields.io/puppetforge/e/puppet/catalog_diff.svg)](https://forge.puppetlabs.com/puppet/catalog_diff)
[![Puppet Forge - scores](https://img.shields.io/puppetforge/f/puppet/catalog_diff.svg)](https://forge.puppetlabs.com/puppet/catalog_diff)
[![puppetmodule.info docs](http://www.puppetmodule.info/images/badge.png)](http://www.puppetmodule.info/m/puppet-catalog-diff)
[![Apache-2 License](https://img.shields.io/github/license/voxpupuli/puppet-catalog_diff.svg)](LICENSE)
[![By Camptocamp](https://img.shields.io/badge/by-camptocamp-fb7047.svg)](http://www.camptocamp.com)


![Catalog Diff](https://raw.githubusercontent.com/voxpupuli/puppet-catalog_diff/master/catalog-diff.png)


#### Table of Contents

1. [Overview](#overview)
1. [Module Description](#module-description)
1. [Setup](#setup)
    1. [Set up node discovery](#set-up-node-discovery)
    1. [Set up auth.conf](#set-up-authconf)
1. [Usage](#usage)
    1. [Multi threaded compile requests](#multi-threaded-compile-requests)
    1. [Fact search](#fact-search)
    1. [Changed depth](#changed-depth)
    1. [Output report](#output-report)
1. [Limitations](#limitations)
1. [Previous Authors](#previous-authors)
1. [Contributors](#contributors)
1. [See Also](#see-also)
    1. [Upload facts to PuppetDB](#upload-facts-to-puppetdb)
    1. [Modern fact submission](#modern-fact-submission)


## Overview

A tool to compare two Puppet catalogs.


## Module Description

While upgrading versions of Puppet or refactoring Puppet code you want to
ensure that no unexpected changes will be made prior to committing the changes.

This tool will allow you to diff catalogs created by different versions of
Puppet or different environments.
This will let you gauge the impact of a change before actually touching
any of your nodes.

This tool is delivered as a collection of Puppet Faces.
It thus requires a Puppet 6.11 (or newer) installation to properly run.

Only the system that runs catalog-diff needs to be using Puppet 6.11 or newer.
The puppetservers you are targeting to do the catalog compilation can be running
an early version of puppet; however puppetdb must be at least version 2.3. You
can use catalog-diff directly on a Puppetserver but also on another server.

The diff tool recognizes catalogs in yaml, marshall, json, or pson formats.
Currently automatic generation of the catalogs is done in the pson format.

The tool can automatically compile the catalogs for both your new and older
servers/environments.
It can ask the master to use PuppetDB to compile the catalog for the last
known environment with the last known facts. It can then validate against PuppetDB
that the node is still active. This filtered list
should contain only machines that have not been decommissioned in PuppetDB (important
as compiling their catalogs would also reactive them and their exports otherwise).

When you are comparing between different versions of Puppet using two Master servers
you are going to need to copy facts from the old Master to the new one in order to be
able to compile catalogs on the new Master. This is useful when upgrading Puppet version.

To upload facts to PuppetDB on a Master see the [Upload facts](#upload-facts-to-puppetdb) script.

## Setup


### Set up node discovery

Node discovery requires an access to the PuppetDB. You'll need either:

* have an unencrypted access to PuppetDB (port 8080, local or proxified)
* generate a set key and certificate signed by the Puppet CA to access the
  PuppetDB

PuppetDB has an (optional) [allowlist](https://www.puppet.com/docs/puppetdb/7/configure.html#certificate-allowlist)
for certificates that are allowed to connect to the database. It's located at
`/etc/puppetlabs/puppetdb/certificate-allowlist`. in Puppet Enterprise you can
configure it like this to allow a specific certificate:

```yaml
puppet_enterprise::profile::puppetdb::allowlisted_certnames:
  - catalog-diff
```

### Set up auth.conf

Once you have set up the discovery, you need to allow access to the "diff" node to
compile the catalogs for all nodes on both your old and new masters.

On Puppet 5+, you need to edit the Puppetserver's
`/etc/puppetlabs/puppetserver/conf.d/auth.conf` file.

In your confdir modify auth.conf to allow access to `/catalog`.
If there is an existing reference i.e. the $1 back reference for machines to
compile their own catalog then simply add another line with the certificate
name of the diff machine. As mentioned this can be the new master as required.

E.g. if you're using Puppet 5, you should have something like:

```ruby
{
    # Allow nodes to retrieve their own catalog
    match-request: {
        path: "^/puppet/v3/catalog/([^/]+)$"
        type: regex
        method: [get, post]
    }
    allow: ["$1","catalog-diff"]
    sort-order: 500
    name: "puppetlabs catalog"
},
```


If you are on Puppet 6, you can activate the certless API instead with:

```ruby
{
    match-request: {
        path: "^/puppet/v4/catalog"
        type: regex
        method: [post]
    }
    allow: ["catalog-diff"]
    sort-order: 500
    name: "puppetlabs certless catalog"
},
```

You can update the `auth.conf` with the following Puppet code (uses the
[puppetlabs/puppet_authorization](https://forge.puppet.com/modules/puppetlabs/puppet_authorization) module):

```puppet
puppet_authorization::rule { 'catalog-diff certless catalog':
  match_request_path   => '^/puppet/v4/catalog',
  match_request_type   => 'regex',
  match_request_method => 'post',
  allow                => 'catalog-diff',
  sort_order           => 500,
  path                 => '/etc/puppetlabs/puppetserver/conf.d/auth.conf',
}
```

The certless API has one big, not so obvious, advantage. It can read trusted
facts from PuppetDB and use them during catalog compilation. Using trusted facts
in Hiera/Puppet code required using the certless API. From the
[API docs](https://puppet.com/docs/puppet/7/server/puppet-api/v4/catalog.html#trusted-facts):

> trusted_facts (API field): A hash with a required values key containing a hash of the trusted facts for a node. In a normal agent's catalog request, these would be extracted from the cert, but this endpoint does not require a cert for the node whose catalog is being compiled. If not provided, Puppet will attempt to fetch the trusted facts for the node from PuppetDB or from the provided facts hash.

## Usage


Example: diff catalogs for `node1.example.com` & `node2.example.com` between
puppetserver `puppet5.example.com`, `puppet6.example.com`. The old catalog will
be fetched from PuppetDB, the new one will be compiled:

```shell
$ puppet module install puppet-catalog_diff
$ puppet catalog diff \
     puppet5.example.com:8140/production puppet6.example.com:8140/production \
     --filter_old_env \
     --old_catalog_from_puppetdb \
     --certless \
     --show_resource_diff \
     --content_diff \
     --ignore_parameters alias \  # Puppet6 removes lots of alias parameters
     \ #--yamldir $YAMLDIR \
     \ #--ssldir $SSLDIR \
     --changed_depth 1000 \
     --configtimeout 1000 \
     --output_report "${HOME}/lastrun-$$.json" \
     --debug \
     \ #--fact_search kernel='Darwin' \
     --threads 50 \
     \ #--node_list=node1.example.com,node2.example.com
```

Example: Compare to local catalogs for `node1.example.com` (we recommend absolute paths):

```shell
$ puppet catalog diff /foo/old/node1.example.com.json /foo/new/node1.example.com.json
```

You can generate them on an agent in a serverless setup:

```shell
puppet catalog compile --render-as json
```

As an alternative an agent can also download its catalog and store it locally:

```shell
puppet catalog download
```

### Multi threaded compile requests

You can change the number of concurrent connections to the masters by passing an interger
to the `--threads` option. This will balence the catalogs evenly on the old and new
masters. This option defaults to 10 and in testing 50 threads seemed correct for
4 masters with two load balancers.

Note: When using catalog diff to compare directories, one thread per catalog
comparison will be created.  However, since Ruby cannot take advantage of
multiple CPUs this may be of limited use comparing local catalogs.  If the
'parallel' gem is installed, then one process will be forked off per CPU on the
system, allowing use of all CPUs.

### Fact search

You can pass `--fact_search` to filter the list of nodes based on a single fact value.
This currently defaults to `kernel=Linux` if you do not pass it.
This query will be passed as a filter to the PuppetDB to retrieve the list of
nodes to compare.

### Node list

Passing `--node_list` will bypass the dynamic generation of node lists from PuppetDB
including the `--fact_search` filter. The list of nodes are not validated against
PuppetDB, and it is up to the user to ensure that the nodes exist and are active.

### Changed depth

Once each catalog is compiled , it is saved to the /tmp directory on the system and the
face will then automatically calculate the differences between the catalogs. Once this
is complete a summary of number of nodes with changes as well as nodes whose catalog
would not compile are listed. You can modify the number of nodes shown here using
`--changed_depth` option.

### Output Report

You can save the last report as json to a specific location using "`--output_report`"
This report will contain the structured data in the format of running this command
with `--render-as json`. An example Rakefile is provided with a `docs` task for
converting this report to (GitHub flavored) markdown. The script above also will
save the output with escaped color. If you want to view that text report run
`less -r lastrun-$$.log`

### Non-default PuppetDB/Configuring PuppetDB

Usually, Puppet uses its default PuppetDB. This is configured in the
`puppetdb.conf`. The file is located at
`$(puppet config print confdir)/puppetdb.conf` (usually
`/etc/puppetlabs/puppet/puppetdb.conf`). It's present by default on all
Puppetservers that talk to a PuppetDB. puppet-catalog-diff will use the first
entry in that file.

It's recommended to run puppet-catalog-diff as a normal user, not as root user.
In that case the `confdir` is different and you need to create the
`puppetdb.conf` explicitly. It's a
[simple ini format](https://puppet.com/docs/puppetdb/latest/puppetdb_connection.html):

```ini
[main]
server_urls = https://fqdn:8081
```

You can even run puppet-catalog-diff as non-root on a system that's not a
Puppetserver. In that case you need to install
[puppetdb-termini](https://puppet.com/docs/puppetdb/latest/connect_puppet_server.html#on-platforms-with-packages)
in addition to the Puppet Agent.

The spec allows you to list multiple PuppetDBs in the `puppetdb.conf`, however
puppet-catalog-diff always uses the first entry. By default, this server will
be used to discover nodes in PuppetDB, to get old catalogs from PuppetDB and to
get new catalogs.

If you like, you can provide two explicit PuppetDB URIs for different purposes.
For node discovery and retrieving old catalogs, you can use
`--old_puppetdb https://fqdn:8081`. To get new catalogs from a specific
Puppetdb, use `--new_puppetdb https://fqdn:8081`.

`puppet catalog diff` works with the TLS certificates that the agent also uses.
You can see the related files by checking `puppet config print | grep ssl`. If
the old PuppetDB uses certificates from a different CA, you can provide those
via CLI options Those are:

* `--old_puppetdb_tls_cert=`
* `--old_puppetdb_tls_key=`
* `--old_puppetdb_tls_ca=`

### Non-default Puppetserver

`puppet catalog diff` can request an old catalog from a Puppetserver. The
Puppetserver will compile a new catalog. By default, catalog-diff will use the
Agent default certificates to connect to the old Puppserver (see the section
above for details). You can provide custom Client TLS certificate/private key
and a CA file:

* `--old_puppetserver_tls_cert=`
* `--old_puppetserver_tls_key=`
* `--old_puppetserver_tls_ca=`

## Limitations

This code only validates the catalogs, it cannot tell you if the behavior of
the providers that interpret the catalog has changed so testing is still
recommended, this is just one tool to take away some of the uncertainty.

You can get some inline help with:

    puppet man catalog

The reports generated by this tool can be rendered as json as well as
viewed in markdown using the Rakefile in this directory.
A web viewer is also available at [https://github.com/voxpupuli/puppet-catalog-diff-viewer](https://github.com/voxpupuli/puppet-catalog-diff-viewer)


## Previous Authors

R.I.Pienaar <rip@devco.net> / www.devco.net / @ripienaar
Zack Smith <zack@puppetlabs.com> / @acidprime
Raphaël Pinson <raphael.pinson@camptocamp.com> / @raphink


## Contributors

The list of contributors can be found at: [https://github.com/voxpupuli/puppet-catalog_diff/graphs/contributors](https://github.com/voxpupuli/puppet-catalog_diff/graphs/contributors).


## See also

### Upload facts to PuppetDB

Standalone Ruby script `upload_facts.rb` that is used to upload yaml files with facts to
PuppetDB. This is useful when you are upgradering Puppet version and uses two different
Puppet Masters for this. Then you can use this script to upload facts from the old Master
to the new one. The script can also be used to just refresh the facts in PuppetDB from
the old Master. These facts are required to be able to compile the catalogs on the new
Master.

The script uses yaml-files in the same format as stored on the Puppet Master when real
agents report their facts at the beginning of a Puppet Agent execution.

The script is developed to be executed on the Puppet Master, so the yaml-facts files
should be copied to the new Master using scp or similar, preferably to the
`$(puppet config print vardir)/yaml/facts` directory.

Then all files in the directory can be uploaded to PuppetDB by using this command:

```shell
$ ./upload_facts.rb $(puppet config print vardir)/yaml/facts/*.yaml
```

The script is available at [https://github.com/JohnEricson/upload_facts](https://github.com/JohnEricson/upload_facts).

It's been verified to work with uploading facts from Puppet Masters running Puppet
version 3 to Masters running version 5. It uses the [`/puppet/v3/facts/` API](https://puppet.com/docs/puppet/6.17/http_api/http_facts.html)
which is available in version 3 and >= 5 of Puppet. This API was removed in Puppet 4 but
added again in 5.

### Modern fact submission

Nowadays it's possible to use `puppet facts upload --server $new_server` to
submit facts to a new server. This however requires that the new puppetserver
and the old one share one certificate authority. You can easily run this once
via bolt to get all facts to a new puppetserver.

### complex fact submission

To every problem an overengineered solution exists! Let's assume this:
You have an existing Puppet environment. You setup a new Puppetserver,
with a newer Puppet version and a new CA. You have a third box with
catalog_diff, that has certificates to access the old and new Puppetserver. Now
for catalog_diff to work, we need to get the facts from the old environment to
the new one. There are three little scripts that you can use to:

* download facts from old PuppetDB
* Convert the format
* Submit them to the new Puppetserver

It's best to run them on the catalog_diff box, since it already has certificates
that allow it to access all required APIs:


```bash
#!/bin/bash


#differ_certs/
#├── catalog-diff_dev
#│   ├── ca
#│   │   └── ca.pem
#│   ├── cert
#│   │   └── catalog-diff.pem
#│   └── private
#│       └── catalog-diff.pem
#├── catalog-diff_prod
#│   ├── ca
#│   │   └── ca.pem
#│   ├── cert
#│   │   └── catalog-diff.pem
#│   └── private
#│       └── catalog-diff.pem


certs_dir="${HOME}/differ_certs"
certs_dev="${certs_dir}/catalog-diff_dev"
certs_prod="${certs_dir}/catalog-diff_prod"
cert='catalog-diff.pem'
puppetdb_dev=puppet-dev.local
puppetdb_prod=puppet-prod.local
clientcert_dev="${certs_dev}/cert/${cert}"
clientcert_prod="${certs_prod}/cert/${cert}"
clientkey_dev="${certs_dev}/private/${cert}"
clientkey_prod="${certs_prod}/private/${cert}"
cacert_dev="${certs_dev}/ca/ca.pem"
cacert_prod="${certs_prod}/ca/ca.pem"

function prod_facts() {
  curl --request GET \
    --url "https://${puppetdb_prod}:8081/pdb/query/v4/factsets" \
    --cert "${clientcert_prod}" \
    --cacert "${cacert_prod}" \
    --key "${clientkey_prod}" \
    --silent \
    | jq -cr '.[] | .certname, .' | awk 'NR%2{f="factsets/"$0".json";next} {print >f;close(f)}'
}

function dev_facts() {
  curl --request GET \
    --url "https://${puppetdb_dev}:8081/pdb/query/v4/factsets" \
    --cert "${clientcert_dev}" \
    --cacert "${cacert_dev}" \
    --key "${clientkey_dev}" \
    --silent \
    | jq -cr '.[] | .certname, .' | awk 'NR%2{f="factsets/"$0".json";next} {print >f;close(f)}'
}

function facts() {
  dev_facts
  prod_facts
}
facts
```

```ruby
#!/opt/puppetlabs/puppet/bin/ruby

require 'json'
require 'date'

Dir[Dir.home + "/factsets/*.json"].each do |file|
  filename = File.basename(file)
  puts "processing #{filename}"
  facts = JSON.parse(File.read(file))
  real_facts = { }
  real_facts['values'] = facts['facts']['data'].map{|facthash| {facthash['name'] => facthash['value']}}.reduce({}, :merge)
  real_facts['name'] = facts['certname']
  real_facts['timestamp'] = facts['timestamp']
  # expiration is usually timestamp + runintervall. We use 30min here
  real_facts['expiration'] = DateTime.parse(facts['timestamp']) + Rational(30 * 60, 86400)
  File.open(Dir.home + "/facts/#{filename}","w") do |f| f.write("#{JSON.pretty_generate(real_facts)}\n") end
end
```

```bash
#!/bin/bash

hostcert="$(puppet config print hostcert)"
hostprivkey="$(puppet config print hostprivkey)"
localcacert="$(puppet config print localcacert)"
server="$(puppet config print server)"
for file in facts/*json; do
  filename="$(basename $file)"
  certname="$(basename $filename '.json')"
  environment="$(jq --raw-output .environment factsets/${filename})"
  curl --include \
    --request PUT \
    --cert "${hostcert}" \
    --key "${hostprivkey}" \
    --cacert "${localcacert}" \
    --data @"${file}" \
    --url "https://${server}:8140/puppet/v3/facts/${certname}?environment=${environment}" \
    --header 'Content-Type: application/json'
done
```

### Further documentation

* Raphaël Pinson wrote a [blog series on dev.to](https://dev.to/camptocamp-ops/diffing-puppet-environments-1fno) about using puppet-catalog-diff and GitLab integration
* Raphaël Pinson also made two talks about it:
  * https://youtu.be/6LOaHsQDsiI - Automated Puppet Impact Analysis with Puppet Catalog Diff and GitLab CI
  * https://youtu.be/o8HP_wcxse4 - Puppet Camp Netherlands: Impact Analysis with Puppet Catalog Diff
