##@file
# Base package for Lemonldap::NG configuration system

##@class
# Implements Lemonldap::NG shared configuration system.
# In case of error or warning, the message is stored in the global variable
# $Lemonldap::NG::Common::Conf::msg
package Lemonldap::NG::Common::Conf;

use strict;
use utf8;
no strict 'refs';
use Lemonldap::NG::Common::Conf::Constants;    #inherits

# TODO: don't import this big file, use a proxy
use Lemonldap::NG::Common::Conf::DefaultValues;    #inherits
use Lemonldap::NG::Common::Crypto
  ;    #link protected cipher Object "cypher" in configuration hash
use Config::IniFiles;

#inherits Lemonldap::NG::Common::Conf::File
#inherits Lemonldap::NG::Common::Conf::DBI
#inherits Lemonldap::NG::Common::Conf::SOAP
#inherits Lemonldap::NG::Common::Conf::LDAP

our $VERSION = '1.9.1';
our $msg     = '';
our $iniObj;

BEGIN {
    eval {
        require threads::shared;
        threads::shared::share($iniObj);
    };
}

## @cmethod Lemonldap::NG::Common::Conf new(hashRef arg)
# Constructor.
# Succeed if it has found a way to access to Lemonldap::NG configuration with
# $arg (or default file). It can be :
# - Nothing: default configuration file is tested,
# - { confFile => "/path/to/storage.conf" },
# - { Type => "File", dirName => "/path/to/conf/dir/" },
# - { Type => "DBI", dbiChain => "DBI:mysql:database=lemonldap-ng;host=1.2.3.4",
# dbiUser => "user", dbiPassword => "password" },
# - { Type => "SOAP", proxy => "https://auth.example.com/index.pl/config" },
# - { Type => "LDAP", ldapServer => "ldap://localhost", ldapConfBranch => "ou=conf,ou=applications,dc=example,dc=com",
#  ldapBindDN => "cn=manager,dc=example,dc=com", ldapBindPassword => "secret"},
#
# $self->{type} contains the type of configuration access system and the
# corresponding package is loaded.
# @param $arg hash reference or hash table
# @return New Lemonldap::NG::Common::Conf object
sub new {
    my $class = shift;
    my $self = bless {}, $class;
    if ( ref( $_[0] ) ) {
        %$self = %{ $_[0] };
    }
    else {
        if ( (@_) && $#_ % 2 == 1 ) {
            %$self = @_;
        }
    }
    unless ( $self->{mdone} ) {
        unless ( $self->{type} ) {

            # Use local conf to get configStorage and localStorage
            my $localconf =
              $self->getLocalConf( CONFSECTION, $self->{confFile}, 0 );
            if ( defined $localconf ) {
                %$self = ( %$self, %$localconf );
            }
        }
        unless ( $self->{type} ) {
            $msg .= "Error: configStorage: type is not defined.\n";
            return 0;
        }
        unless ( $self->{type} =~ /^[\w:]+$/ ) {
            $msg .= "Error: configStorage: type is not well formed.\n";
        }
        $self->{type} = "Lemonldap::NG::Common::Conf::$self->{type}"
          unless $self->{type} =~ /^Lemonldap::/;
        eval "require $self->{type}";
        if ($@) {
            $msg .= "Error: Unknown package $self->{type}.\n";
            return 0;
        }
        return 0 unless $self->prereq;
        $self->{mdone}++;
        $msg = "$self->{type} loaded.\n";
    }
    if ( $self->{localStorage} and not defined( $self->{refLocalStorage} ) ) {
        eval "use $self->{localStorage};";
        if ($@) {
            $msg .= "Unable to load $self->{localStorage}: $@.\n";
        }

        # TODO: defer that until $> > 0 (to avoid creating local cache with
        # root privileges
        else {
            $self->{refLocalStorage} =
              $self->{localStorage}->new( $self->{localStorageOptions} );
        }
    }
    return $self;
}

## @method int saveConf(hashRef conf, hash args)
# Serialize $conf and call store().
# @param $conf Lemonldap::NG configuration hashRef
# @param %args Parameters
# @return Number of the saved configuration, 0 in case of error.
sub saveConf {
    my ( $self, $conf, %args ) = @_;

    my $last = $self->lastCfg;

    # If configuration was modified, return an error
    if ( not $args{force} ) {
        return CONFIG_WAS_CHANGED if ( $conf->{cfgNum} != $last );
        return DATABASE_LOCKED if ( $self->isLocked() or not $self->lock() );
    }
    $conf->{cfgNum} = $last + 1 unless ( $args{cfgNumFixed} );
    delete $conf->{cipher};

    # Try to store configuration
    my $tmp = $self->store($conf);

    unless ( $tmp > 0 ) {
        $msg .= "Configuration $conf->{cfgNum} not stored.\n";
        $self->unlock();
        return ( $tmp ? $tmp : UNKNOWN_ERROR );
    }

    $msg .= "Configuration $conf->{cfgNum} stored.\n";
    return ( $self->unlock() ? $tmp : UNKNOWN_ERROR );
}

## @method hashRef getConf(hashRef args)
# Get configuration from remote configuration storage system or from local
# cache if configuration has not been changed. If $args->{local} is set and if
# a local configuration is available, remote configuration is not tested.
#
# Uses lastCfg to test and getDBConf() to get the remote configuration
# @param $args Optional, contains {local=>1} or nothing
# @return Lemonldap::NG configuration
sub getConf {
    my ( $self, $args ) = @_;

    # Use only cache to get conf if $args->{local} is set
    if (    $>
        and $args->{local}
        and ref( $self->{refLocalStorage} )
        and my $res = $self->{refLocalStorage}->get('conf') )
    {
        $msg .= "Get configuration from cache without verification.\n";
        return $res;
    }

    # Check cfgNum in conf backend
    # Get conf in backend only if a newer configuration is available
    else {
        $args->{cfgNum} ||= $self->lastCfg;
        unless ( $args->{cfgNum} ) {
            $msg .= "No configuration available in backend.\n";
        }
        my $r;
        unless ( ref( $self->{refLocalStorage} ) ) {
            $msg .= "Get remote configuration (localStorage unavailable).\n";
            $r = $self->getDBConf($args);
        }
        else {
            eval { $r = $self->{refLocalStorage}->get('conf') }
              if ( $> and not $args->{noCache} );
            $msg = "Warn: $@" if ($@);
            if (    ref($r)
                and $r->{cfgNum}
                and $args->{cfgNum}
                and $r->{cfgNum} == $args->{cfgNum} )
            {
                $msg .=
                  "Configuration unchanged, get configuration from cache.\n";
                $args->{noCache} = 1;
            }
            else {
                $r = $self->getDBConf($args);
                return undef unless ( $r->{cfgNum} );

                # TODO: default values may not be set here
                unless ( $args->{raw} ) {

                    # Adapt some values before storing in local cache
                    # Get default values
                    my $defaultValues =
                      Lemonldap::NG::Common::Conf::DefaultValues
                      ->defaultValues();

                    foreach my $k ( keys %$defaultValues ) {
                        $r->{$k} //= $defaultValues->{$k};
                    }
                }

                # Convert old option useXForwardedForIP into trustedProxies
                if ( defined $r->{useXForwardedForIP}
                    and $r->{useXForwardedForIP} == 1 )
                {
                    $r->{trustedProxies} = '*';
                    delete $r->{useXForwardedForIP};
                }

                # Force Choice backend
                if ( $r->{authentication} eq "Choice" ) {
                    $r->{userDB}     = "Choice";
                    $r->{passwordDB} = "Choice";
                }

            # Some parameters expect key name (example), not variable ($example)
                foreach (qw/whatToTrace/) {
                    if ( defined $r->{$_} ) {
                        $r->{$_} =~ s/^\$//;
                    }
                }

                # Store modified configuration in cache
                $self->setLocalConf($r)
                  if ( $self->{refLocalStorage}
                    and not( $args->{noCache} or $args->{raw} ) );

            }
        }

        # Create cipher object
        unless ( $args->{raw} ) {
            eval {
                $r->{cipher} = Lemonldap::NG::Common::Crypto->new( $r->{key} );
            };
            if ($@) {
                $msg .= "Bad key: $@. \n";
            }
        }

        # Return configuration hash
        return $r;
    }
}

## @method hashRef getLocalConf(string section, string file, int loaddefault)
# Get configuration from local file
#
# @param $section Optional section name (default DEFAULTSECTION)
# @param $file Optional file name (default DEFAULTCONFFILE)
# @param $loaddefault Optional load default section parameters (default 1)
# @return Lemonldap::NG configuration
sub getLocalConf {
    my ( $self, $section, $file, $loaddefault ) = @_;
    my $r = {};

    $section ||= DEFAULTSECTION;
    $file ||=
         $self->{confFile}
      || $ENV{LLNG_DEFAULTCONFFILE}
      || DEFAULTCONFFILE;
    $loaddefault = 1 unless ( defined $loaddefault );
    my $cfg;

    # First, search if this file has been parsed
    unless ( $cfg = $iniObj->{$file} ) {

        # If default configuration cannot be read
        # - Error if configuration section is requested
        # - Silent exit for other section requests
        unless ( -r $file ) {
            if ( $section eq CONFSECTION ) {
                $msg .=
                  "Cannot read $file to get configuration access parameters.\n";
                return $r;
            }
            return $r;
        }

        # Parse ini file
        $cfg = Config::IniFiles->new( -file => $file, -allowcontinue => 1 );

        unless ( defined $cfg ) {
            $msg .= "Local config error: " . @Config::IniFiles::errors . "\n";
            return $r;
        }

        # Check if default section exists
        unless ( $cfg->SectionExists(DEFAULTSECTION) ) {
            $msg .= "Default section (" . DEFAULTSECTION . ") is missing. \n";
            return $r;
        }

        # Check if configuration section exists
        if ( $section eq CONFSECTION and !$cfg->SectionExists(CONFSECTION) ) {
            $msg .= "Configuration section (" . CONFSECTION . ") is missing.\n";
            return $r;
        }
    }

    # First load all default section parameters
    if ($loaddefault) {
        foreach ( $cfg->Parameters(DEFAULTSECTION) ) {
            $r->{$_} = $cfg->val( DEFAULTSECTION, $_ );
            if ( $r->{$_} =~ /^[{\[].*[}\]]$/ || $r->{$_} =~ /^sub\s*{.*}$/ ) {
                eval "\$r->{$_} = $r->{$_}";
                if ($@) {
                    $msg .= "Warning: error in file $file: $@.\n";
                    return $r;
                }
            }
        }
    }

    # Stop if the requested section is the default section
    return $r if ( $section eq DEFAULTSECTION );

    # Check if requested section exists
    return $r unless $cfg->SectionExists($section);

    # Load section parameters
    foreach ( $cfg->Parameters($section) ) {
        $r->{$_} = $cfg->val( $section, $_ );
        if ( $r->{$_} =~ /^[{\[].*[}\]]$/ || $r->{$_} =~ /^sub\s*{.*}$/ ) {
            eval "\$r->{$_} = $r->{$_}";
            if ($@) {
                $msg .= "Warning: error in file $file: $@.\n";
                return $r;
            }
        }
    }

    return $r;
}

## @method void setLocalConf(hashRef conf)
# Store $conf in the local cache.
# @param $conf Lemonldap::NG configuration hashRef
sub setLocalConf {
    my ( $self, $conf ) = @_;
    return unless ($>);
    eval { $self->{refLocalStorage}->set( "conf", $conf ) };
    $msg .= "Warn: $@\n" if ($@);
}

## @method hashRef getDBConf(hashRef args)
# Get configuration from remote storage system.
# @param $args hashRef that must contains a key "cfgNum" (number of the wanted
# configuration) and optionaly a key "fields" that points to an array of wanted
# configuration keys
# @return Lemonldap::NG configuration hashRef
sub getDBConf {
    my ( $self, $args ) = @_;
    return undef unless $args->{cfgNum};
    if ( $args->{cfgNum} < 0 ) {
        my @a = $self->available();
        $args->{cfgNum} =
            ( @a + $args->{cfgNum} > 0 )
          ? ( $a[ $#a + $args->{cfgNum} ] )
          : $a[0];
    }
    my $conf = $self->load( $args->{cfgNum} );
    $msg .= "Get configuration $conf->{cfgNum}.\n"
      if ( defined $conf->{cfgNum} );
    $self->setLocalConf($conf)
      if (  ref($conf)
        and $self->{refLocalStorage}
        and not( $args->{noCache} ) );
    return $conf;
}

## @method boolean prereq()
# Call prereq() from the $self->{type} package.
# @return True if succeed
sub prereq {
    return &{ $_[0]->{type} . '::prereq' }(@_);
}

## @method @ available()
# Call available() from the $self->{type} package.
# @return list of available configuration numbers
sub available {
    return &{ $_[0]->{type} . '::available' }(@_);
}

## @method int lastCfg()
# Call lastCfg() from the $self->{type} package.
# @return Number of the last configuration available
sub lastCfg {
    my $result = &{ $_[0]->{type} . '::lastCfg' }(@_) || "0";
    return $result;
}

## @method boolean lock()
# Call lock() from the $self->{type} package.
# @return True if succeed
sub lock {
    return &{ $_[0]->{type} . '::lock' }(@_);
}

## @method boolean isLocked()
# Call isLocked() from the $self->{type} package.
# @return True if database is locked
sub isLocked {
    return &{ $_[0]->{type} . '::isLocked' }(@_);
}

## @method boolean unlock()
# Call unlock() from the $self->{type} package.
# @return True if succeed
sub unlock {
    return &{ $_[0]->{type} . '::unlock' }(@_);
}

## @method int store(hashRef conf)
# Call store() from the $self->{type} package.
# @param $conf Lemondlap configuration serialized
# @return Number of new configuration stored if succeed, 0 else.
sub store {
    return &{ $_[0]->{type} . '::store' }(@_);
}

## @method load(int cfgNum, arrayRef fields)
# Call load() from the $self->{type} package.
# @return Lemonldap::NG Configuration hashRef if succeed, 0 else.
sub load {
    return &{ $_[0]->{type} . '::load' }(@_);
}

## @method boolean delete(int cfgNum)
# Call delete() from the $self->{type} package.
# @param $cfgNum Number of configuration to delete
# @return True if succeed
sub delete {
    my ( $self, $c ) = @_;
    my @a = $self->available();
    if ( grep( /^$c$/, @a ) ) {
        return &{ $self->{type} . '::delete' }( $self, $c );
    }
    else {
        return 0;
    }
}

sub logError {
    return &{ $_[0]->{type} . '::logError' }(@_);
}

1;
__END__

=head1 NAME

=encoding utf8

Lemonldap::NG::Common::Conf - Perl extension written to manage Lemonldap::NG
Web-SSO configuration.

=head1 SYNOPSIS

  use Lemonldap::NG::Common::Conf;
  my $confAccess = new Lemonldap::NG::Common::Conf(
              {
                  type=>'File',
                  dirName=>"/tmp/",

                  # To use local cache, set :
                  localStorage => "Cache::FileCache",
                  localStorageOptions = {
                      'namespace' => 'lemonldap-ng-config',
                      'default_expires_in' => 600,
                      'directory_umask' => '007',
                      'cache_root' => '/tmp',
                      'cache_depth' => 5,
                  },
              },
    ) or die "Unable to build Lemonldap::NG::Common::Conf, see Apache logs";
  my $config = $confAccess->getConf();

=head1 DESCRIPTION

Lemonldap::NG::Common::Conf provides a simple interface to access to
Lemonldap::NG Web-SSO configuration. It is used by L<Lemonldap::NG::Handler>,
L<Lemonldap::NG::Portal> and L<Lemonldap::NG::Manager>.

=head2 SUBROUTINES

=over

=item * B<new> (constructor): it takes different arguments depending on the
chosen type. Examples:

=over

=item * B<File>:
  $confAccess = new Lemonldap::NG::Common::Conf(
                {
                type    => 'File',
                dirName => '/var/lib/lemonldap-ng/',
                });

=item * B<DBI>:
  $confAccess = new Lemonldap::NG::Common::Conf(
                {
                type        => 'DBI',
                dbiChain    => 'DBI:mysql:database=lemonldap-ng;host=1.2.3.4',
                dbiUser     => 'lemonldap'
                dbiPassword => 'pass'
                dbiTable    => 'lmConfig',
                });

=item * B<SOAP>:
  $confAccess = new Lemonldap::NG::Common::Conf(
                {
                type         => 'SOAP',
                proxy        => 'http://auth.example.com/index.pl/config',
                proxyOptions => {
                                timeout => 5,
                                },
                });

SOAP configuration access is a sort of proxy: the portal is configured to use
the real session storage type (DBI or File for example). See HTML documentation
for more.

=item * B<LDAP>:
  $confAccess = new Lemonldap::NG::Common::Conf(
                {
                type             => 'LDAP',
                ldapServer       => 'ldap://localhost',
                ldapConfBranch   => 'ou=conf,ou=applications,dc=example,dc=com',
                ldapBindDN       => 'cn=manager,dc=example,dc=com",
                ldapBindPassword => 'secret'
                });

=back

WARNING: You have to use the same storage type on all Lemonldap::NG parts in
the same server.

=item * B<getConf>: returns a hash reference to the configuration. it takes
a hash reference as first argument containing 2 optional parameters:

=over

=item * C<cfgNum => $number>: the number of the configuration wanted. If this
argument is omitted, the last configuration is returned.

=item * C<fields => [array of names]: the desired fields asked. By default,
getConf returns all (C<select * from lmConfig>).

=back

=item * B<saveConf>: stores the Lemonldap::NG configuration passed in argument
(hash reference). it returns the number of the new configuration.

=back

=head1 SEE ALSO

L<Lemonldap::NG::Handler>, L<Lemonldap::NG::Portal>,
L<http://lemonldap-ng.org/>

=head1 AUTHOR

=over

=item Clement Oudot, E<lt>clem.oudot@gmail.comE<gt>

=item François-Xavier Deltombe, E<lt>fxdeltombe@gmail.com.E<gt>

=item Xavier Guimard, E<lt>x.guimard@free.frE<gt>

=item Sandro Cazzaniga, E<lt>cazzaniga.sandro@gmail.comE<gt>

=back

=head1 BUG REPORT

Use OW2 system to report bug or ask for features:
L<http://jira.ow2.org>

=head1 DOWNLOAD

Lemonldap::NG is available at
L<http://forge.objectweb.org/project/showfiles.php?group_id=274>

=head1 COPYRIGHT AND LICENSE

=over

=item Copyright (C) 2008-2016 by Xavier Guimard, E<lt>x.guimard@free.frE<gt>

=item Copyright (C) 2012 by Sandro Cazzaniga, E<lt>cazzaniga.sandro@gmail.comE<gt>

=item Copyright (C) 2012 by François-Xavier Deltombe, E<lt>fxdeltombe@gmail.com.E<gt>

=item Copyright (C) 2009-2016 by Clement Oudot, E<lt>clem.oudot@gmail.comE<gt>

=back

This library is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2, or (at your option)
any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see L<http://www.gnu.org/licenses/>.

=cut
