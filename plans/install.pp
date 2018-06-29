plan pe_xl::install (
  String[1]           $version = '2018.1.2',
  String[1]           $console_password,

  String[1]           $primary_master_host,
  String[1]           $puppetdb_database_host,
  Array[String[1]]    $compile_master_hosts = [ ],
  Array[String[1]]    $dns_alt_names = [ ],
  Optional[String[1]] $load_balancer_host = undef,

  Optional[String[1]] $r10k_remote = undef,
  String[1]           $pe_environment = 'pe',

  Optional[String[1]] $primary_master_replica_host = undef,
  Optional[String[1]] $puppetdb_database_replica_host = undef,

  String[1]           $stagingdir = '/tmp',
) {

  $all_hosts = [
    $primary_master_host, 
    $puppetdb_database_host,
    $compile_master_hosts,
    $load_balancer_host,
    $primary_master_replica_host,
    $puppetdb_database_replica_host,
  ].pe_xl::flatten_compact()

  $pe_installer_hosts = [
    $primary_master_host, 
    $puppetdb_database_host,
    $primary_master_replica_host,
  ].pe_xl::flatten_compact()

  $agent_installer_hosts = [
    $compile_master_hosts,
    $load_balancer_host,
    $primary_master_replica_host,
  ].pe_xl::flatten_compact()


  $dns_alt_names_csv = $dns_alt_names.reduce |$csv,$x| { "${csv},${x}" }

  # Validate that the name given for each system is both a resolvable name AND
  # the configured hostname.
  run_task('pe_xl::hostname', $all_hosts).each |$task| {
    if $task.target.name != $task['_output'].chomp {
      fail_plan("Hostname / DNS name mismatch: ${task}")
    }
  }

  # Generate all the needed pe.conf files
  $primary_master_pe_conf = epp('pe_xl/primary_master-pe.conf.epp',
    console_password       => $console_password,
    primary_master_host    => $primary_master_host,
    puppetdb_database_host => $puppetdb_database_host,
    dns_alt_names          => $dns_alt_names,
  )

  $puppetdb_database_pe_conf = epp('pe_xl/puppetdb_database-pe.conf.epp',
    primary_master_host    => $primary_master_host,
    puppetdb_database_host => $puppetdb_database_host,
  )

  $puppetdb_database_replica_pe_conf = epp('pe_xl/puppetdb_database-pe.conf.epp',
    primary_master_host    => $primary_master_host,
    puppetdb_database_host => $puppetdb_database_replica_host,
  )

  # Upload the pe.conf files to the hosts that need them
  pe_xl::file_content_upload($primary_master_pe_conf, '/tmp/pe.conf', $primary_master_host)
  pe_xl::file_content_upload($puppetdb_database_pe_conf, '/tmp/pe.conf', $puppetdb_database_host)
  pe_xl::file_content_upload($puppetdb_database_replica_pe_conf, '/tmp/pe.conf', $puppetdb_database_replica_host)

  # Download the PE tarball and send it to the nodes that need it
  $pe_tarball = "puppet-enterprise-${version}-el-7-x86_64.tar.gz"
  $pe_src  = "${stagingdir}/${pe_tarball}"
  $pe_dest = "/tmp/${pe_tarball}"

  pe_xl::retrieve_and_upload(
    "https://s3.amazonaws.com/pe-builds/released/${version}/puppet-enterprise-${version}-el-7-x86_64.tar.gz",
    $pe_src,
    $pe_dest,
    [$primary_master_host, $puppetdb_database_host, $puppetdb_database_replica_host]
  )

  # Create csr_attributes.yaml files for the nodes that need them
  run_task('pe_xl::mkdir_p_file', $primary_master_host,
    path    => '/etc/puppetlabs/puppet/csr_attributes.yaml',
    content => @("HEREDOC"),
      ---
      extension_requests:
        pp_application: "puppet"
        pp_role: "pe_xl::primary_master"
        pp_cluster: "A"
      | HEREDOC
  )

  run_task('pe_xl::mkdir_p_file', $puppetdb_database_host,
    path    => '/etc/puppetlabs/puppet/csr_attributes.yaml',
    content => @("HEREDOC"),
      ---
      extension_requests:
        pp_application: "puppet"
        pp_role: "pe_xl::puppetdb_database"
        pp_cluster: "A"
      | HEREDOC
  )

  run_task('pe_xl::mkdir_p_file', $puppetdb_database_replica_host,
    path    => '/etc/puppetlabs/puppet/csr_attributes.yaml',
    content => @("HEREDOC"),
      ---
      extension_requests:
        pp_application: "puppet"
        pp_role: "pe_xl::puppetdb_database"
        pp_cluster: "B"
      | HEREDOC
  )

  # Get the primary master installation up and running. The installer will
  # "fail" because PuppetDB can't start. That's expected.
  without_default_logging() || {
    notice("Starting: task pe_xl::pe_install on ${primary_master_host}")
    run_task('pe_xl::pe_install', $primary_master_host,
      _catch_errors         => true,
      tarball               => $pe_dest,
      peconf                => '/tmp/pe.conf',
      shortcircuit_puppetdb => true,
    )
    notice("Finished: task pe_xl::pe_install on ${primary_master_host}")
  }

  # Configure autosigning for the puppetdb database hosts 'cause they need it
  run_task('pe_xl::mkdir_p_file', $primary_master_host,
    path    => '/etc/puppetlabs/puppet/autosign.conf',
    owner   => 'pe-puppet',
    group   => 'pe-puppet',
    mode    => '0644',
    content => @("HEREDOC"),
      $puppetdb_database_host
      $puppetdb_database_replica_host
      | HEREDOC
  )

  # Run the PE installer on the puppetdb database hosts
  run_task('pe_xl::pe_install', [$puppetdb_database_host, $puppetdb_database_replica_host],
    tarball => $pe_tarball,
    peconf  => '/tmp/pe.conf',
  )

  # Now that the main PuppetDB database node is ready, start PuppetDB on the primary master
  run_command('systemctl start pe-puppetdb', $primary_master_host)

  # Deploy the PE agent to all remaining hosts
  run_task('pe_xl::agent_install', $primary_master_replica_host,
    server        => $primary_master_host,
    install_flags => [
      '--puppet-service-ensure', 'stopped',
      "main:dns_alt_names=${dns_alt_names_csv}",
      'extension_requests:pp_application=puppet',
      'extension_requests:pp_role=pe_xl::primary_master',
      'extension_requests:pp_cluster=B',
    ],
  )

  # TODO: Split the compile masters into two pools, A and B.
  run_task('pe_xl::agent_install', $compile_master_hosts,
    server        => $primary_master_host,
    install_flags => [
      '--puppet-service-ensure', 'stopped',
      "main:dns_alt_names=${dns_alt_names_csv}",
      'extension_requests:pp_application=puppet',
      'extension_requests:pp_role=pe_xl::compile_master',
      'extension_requests:pp_cluster=A',
    ],
  )

  if $load_balancer_host {
    run_task('pe_xl::agent_install', $load_balancer_host,
      server        => $primary_master_host,
      install_flags => [
        '--puppet-service-ensure', 'stopped',
        'extension_requests:pp_application=puppet',
        'extension_requests:pp_role=pe_xl::load_balancer',
      ],
    )
  }

  # Do a Puppet agent run to ensure certificate requests have been submitted
  # These runs will "fail", and that's expected.
  without_default_logging() || {
    notice("Starting: task pe_xl::puppet_runonce on ${agent_installer_hosts}")
    run_task('pe_xl::puppet_runonce', $agent_installer_hosts, {_catch_errors => true})
    notice("Finished: task pe_xl::puppet_runonce on ${agent_installer_hosts}")
  }

  run_command(inline_epp(@(HEREDOC)), $primary_master_host)
    puppet cert sign \
      <% $agent_installer_hosts.each |$host| { -%>
      <%= $host %> \
      <% } -%>
      --allow-dns-alt-names
    | HEREDOC

  run_task('pe_xl::puppet_runonce', $agent_installer_hosts)
  run_task('pe_xl::puppet_runonce', $pe_installer_hosts)

  return('Installation succeeded')
}
