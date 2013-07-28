class tahoe {
  case $operatingsystem {
    Debian:  { include tahoe::debian }
    ubuntu:  { include tahoe::ubuntu }
    default: { include tahoe::base }
  }
}

class tahoe::base {
}

class tahoe::egg inherits tahoe::base {
  package{
    'python':
      ensure => present;
    'python-dev':
      ensure => present;
    'python-setuptools':
      ensure => present;
    'build-essential':
      ensure => present;
    'libcrypto++-dev':
      ensure => present;
    'python-twisted':
      ensure => present;
    'python-pyopenssl':
      ensure => present;
  }

  exec {'easy_install allmydata-tahoe':
    path   => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    unless => "python -c 'import allmydata'",
  }
}

class tahoe::debian inherits tahoe::base {
  # BUG: Those packages are not authenticated

  case $lsbdistcodename {
    etch:     { $dist = 'etch' }
    lenny:    { $dist = 'etch' }
    intrepid: { $dist = 'hardy' }
    default:  { fail "Unsupported distribution $lsbdistcodename" }
  }

  apt::sources_list {'allmydata':
    ensure => present,
    content => "deb http://allmydata.org/debian/ ${dist} main tahoe
deb-src http://allmydata.org/debian/ ${dist} main tahoe",
  }

  package {'tahoe-lafs':
    name   => 'allmydata-tahoe',
    ensure => 'latest',
  }
}

class tahoe::ubuntu inherits tahoe::base {
  case $lsbdistcodename {
    maverick: { $dist = 'maverick' }
    lucid:    { $dist = 'lucid' }
    karmic:   { $dist = 'karmic' }
    default:  { fail "Unsupported distribution $lsbdistcodename" }
  }
  
  package {'tahoe-lafs':
    ensure => 'latest',
  }
}

define tahoe::introducer (
  $ensure  = present,
  $directory,
  $webport = false,
) {
  tahoe::node {$name:
    ensure    => $ensure,
    directory => $directory,
    type      => 'introducer',
    webport   => $webport,
  }

  if $webport {
    augeas {"tahoe/${name}/webport":
      context   => "/files${directory}/tahoe.cfg",
      load_path => $directory,
      changes   => "set /node/web.port ${webport}",
    }
  }
}

define tahoe::storage (
  $ensure              = present,
  $directory,
  $introducer_furl,
  $webport             = false,
  $stats_gatherer_furl = false,
  $helper_furl         = false,
) {
  tahoe::client {$name:
    ensure              => $ensure,
    directory           => $directory,
    introducer_furl     => $introducer_furl,
    webport             => $webport,
    stats_gatherer_furl => $stats_gatherer_furl,
    helper_furl         => $helper_furl,
    storage             => true,
  }
}

define tahoe::helper (
  $ensure              = present,
  $directory,
  $introducer_furl,
  $webport             = false,
  $stats_gatherer_furl = false,
) {
  tahoe::client {$name:
    ensure                => $ensure,
    directory             => $directory,
    introducer_furl       => $introducer_furl,
    webport               => $webport,
    stats_gatherer_furl   => $stats_gatherer_furl,
    helper                => true,
  }
}

define tahoe::client (
  $ensure              = present,
  $directory,
  $introducer_furl,
  $webport             = 'tcp:3456:interface=127.0.0.1',
  $stats_gatherer_furl = false,
  $helper_furl         = false,
  $storage             = false,
  $helper              = false,
) {
  tahoe::node {$name:
    ensure              => $ensure,
    directory           => $directory,
    type                => 'client',
    introducer_furl     => $introducer_furl,
    webport             => $webport,
    stats_gatherer_furl => $stats_gatherer_furl,
    helper_furl         => $helper_furl,
    storage             => $storage,
    helper              => $helper,
  }
}

define tahoe::stats-gatherer (
  $ensure = present,
  $directory,
) {
  tahoe::node {$name:
    ensure    => $ensure,
    directory => $directory,
    type      => 'stats-gatherer',
  }
}

define tahoe::node (
  $ensure = present,
  $directory,
  $type,
  $introducer_furl     = false,
  $nickname            = "${name}@${fqdn}",
  $webport,
  $stats_gatherer_furl = false,
  $helper_furl         = false,
  $storage             = false,
  $helper              = false,
  ) {
  case $type {
    client,introducer,stats-gatherer: {}
    default: { fail "unknown node type: ${type}" }
  }

  $tahoe_cfg = "${directory}/tahoe.cfg"
  $user = "tahoe-${name}"

  case $ensure {
    present: {
      Package['tahoe-lafs']->
      User[$user]->File[$directory]->
      Exec["create ${type} ${name}"]->
      File["/etc/init.d/tahoe-${name}"]->
      Exec["update-rc.d tahoe-${name} defaults"]->
      File[$tahoe_cfg]~>Service["tahoe-${name}"]
    }
    absent: {
      Service["tahoe-${name}"]->
      Exec["update-rc.d -f tahoe-${name} remove"]->
      File["/etc/init.d/tahoe-${name}"]->
      File[$tahoe_cfg]->File[$directory]->
      User[$user]->Package['tahoe-lafs']
    }
    default: { fail "invalid ensure value: ${ensure}" }
  }

  user {$user:
    ensure => $ensure,
    home   => $directory,
  }

  case $ensure {
    present: {
      file {$directory:
        ensure => 'directory',
        owner  => $user,
        mode   => 700,
      }
    }
    absent: {
      file {$directory:
        ensure => absent,
        force  => true,
      }
    }
  }

  file {"/etc/init.d/tahoe-${name}":
    ensure  => $ensure,
    content => template('tahoe/tahoe.init.erb'),
    mode    => 755,
  }

  #
  # Configuration
  #
  file {$tahoe_cfg:
    ensure  => $ensure,
    content => template('tahoe/tahoe.cfg.erb'),
  }

  #
  # Service
  #
  service {"tahoe-${name}":
    ensure  => $ensure ? {
      present => running,
      absent  => stopped,
    },
  }

  case $ensure {
    present: {
      exec {"create ${type} ${name}":
        command   => "tahoe create-${type} --basedir=${directory}",
        path      => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        user      => $user,
        logoutput => on_failure,
        creates   => "${directory}/tahoe-${type}.tac",
      }

      exec {"update-rc.d tahoe-${name} defaults":
        path    => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        creates => "/etc/rc2.d/S20tahoe-${name}",
      }
    }

    absent: {
      exec {"update-rc.d -f tahoe-${name} remove":
        path   => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        onlyif => "test -f /etc/rc2.d/S20tahoe-${name}",
      }
    }
  }
}
