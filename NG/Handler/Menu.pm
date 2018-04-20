##@file
# Menu

##@class
# Menu
#
# Display a menu on protected applications
package Lemonldap::NG::Handler::Menu;

use strict;
use Lemonldap::NG::Handler::SharedConf qw(:all);
use Lemonldap::NG::Handler::API qw(:httpCodes);
use SOAP::Lite;
use JSON;
use Data::Dumper;
use Lemonldap::NG::Portal::Simple;
use Lemonldap::NG::Handler::Main::Logger;
use base qw(Lemonldap::NG::Handler::SharedConf);
use Apache2::Filter ();
use constant BUFF_LEN => 8192;
$ENV{HTTPS_CA_FILE} = "/etc/apache2/ssl/CA.pem";

sub handler {
    my $r = pop;
    __PACKAGE__->run($r);
}

## @rmethod Apache2::Const run(Apache2::Filter f)
# Overload main run method
# @param f Apache2 Filter
# @return Apache2::Const::OK
sub getAppsList {

	my $class = shift;
	my $f = $_[0];
	my $soap = SOAP::Lite->service('file:/var/lib/lemonldap-ng/portal/portal.wsdl', 'sessionsService', 'sessionsPort');

        Lemonldap::NG::Handler::API->newRequest($f->r);
	my $cookie = Lemonldap::NG::Handler::API->header_in('Cookie');
	$cookie =~ s/^.*=//;
        $f->r->headers_out->unset('Cookie');

	my $om = $soap->getMenuApplications($cookie);
	if ($@) {
	    die $@;
	}

	my $att = $soap->getAttributes($cookie);
	if ($@) {
	    die $@;
	}

	my $listAppsWeight = _unbuildSoapAttributes($att);
	my $listAppsHTML = _unbuildSoapHash($om, \$listAppsWeight);

	return $listAppsHTML;

}

## @rmethod Apache2::Const run(Apache2::Filter f)
# Overload main run method
# @param f Apache2 Filter
# @return Apache2::Const::OK
sub run {
    my $class = shift;
    my $f     = $_[0];

    # Few actions that must be done at server startup:
    # * set log level for Lemonldap::NG logs
    Lemonldap::NG::Handler::Main::Logger->logLevelInit( 'debug' );

    unless ( $f->ctx ) {
        $f->r->headers_out->unset('Content-Length');
        $f->ctx(1);
    }

    # CSS parameters
    my $background  = "#ccc";
    my $border      = "#aaa";
    my $width       = "30%";
    my $marginleft  = "35%";
    my $marginright = "35%";

    my $listAppsHtml = $class->getAppsList($f);
    my $menudiv = qq(
<style>
#lemonldap-ng-menu {
    background-color: $background;
    border-color: $border;
    border-width: 2px 2px 0 2px;
    border-style: solid;
    border-top-left-radius: 10px;
    border-top-right-radius: 10px;
    width: $width;
    margin-right: $marginright;
    margin-left: $marginleft;
    position: absolute;
    bottom: 0px;
    text-align: center;
    padding: 3px;
    z-index: 2;
}
html>body #lemonldap-ng-menu {
    position: fixed;
}
</style>
<div id="lemonldap-ng-menu">
<a href=") . $tsv->{portal}->() . qq(">☖ Home</a>
<span>  </span>
<a href=") . $tsv->{portal}->() . qq(?logout=1">☒ Logout</a>
<a href="" class="menu-burger" id="menu-burger">&#9776; mes applications</a>
<div id="apps-list" class="apps-list">
);

    $menudiv .= qq($listAppsHtml);

    # div id="apps-list"
    $menudiv .= qq(</div>);
# div id="lemonldap-ng-menu"
$menudiv .= qq(</div>);

    #my $skin = Lemonldap::NG::Portal::Simple::getSkin();
    #print "SKIN:" . $skin ."\n";

    while ( $f->read( my $buffer, BUFF_LEN ) ) {
        $buffer =~ s/<\/body>/$menudiv<\/body>/g;
        $f->print($buffer);
    }

    return OK;

}

#######################
# Private subroutines #
#######################

sub _sortApps {
    my ( $h, $weighedApps ) = @_;
    my @tmp = ();
    my @sortedApp = ();

    for my $myKey ( %$$weighedApps ) {
        $tmp[ $$weighedApps->{ $myKey } ] = $myKey;
    }

    my $indSort = 0;
    for(my $ind=0; $ind < @tmp; $ind ++) {
        for(my $ind1=0; $ind1 < @{$h}; $ind1 ++) {
            if ( $h->[$ind1]->{'appid'} eq $tmp[$ind] ) {
                $sortedApp[$indSort] = $h->[$ind1];
                $indSort ++;
            }
        }
    }

    # Applications without weight are added at the end of the array
    my $found = 0;
    for(my $ind1=0; $ind1 < @{$h}; $ind1 ++) {
        for(my $ind=0; $ind < @tmp; $ind ++) {
            if ( $h->[$ind1]->{'appid'} eq $tmp[$ind] ) {
                $found = 1;
            }
        }

        if ( $found eq 0 ) {
            $sortedApp[$indSort] = $h->[$ind1];
            $indSort ++;
        }

        $found = 0;
    }

    return @sortedApp;
}

##@fn private string_unbuildSoapHash(SOAP::Data)
# Serialize a hashref into SOAP::Data. Types are fixed to "string".
# @return SOAP::Data serialized datas
sub _unbuildSoapHash {
    my ( $h, $weighedApps, @keys ) = @_;
    my $htmlMenu = '';

    for(my $ind1 = 0; $ind1 < @{$h->{'menu'}}; $ind1 ++) {

        my $catName = qq(<ul class="). $h->{'menu'}->[$ind1]->{'catname'} . qq(">);
        $htmlMenu .= $catName . "\n";

        $htmlMenu .= qq(<li class="list-title">) . $h->{'menu'}->[$ind1]->{'catname'} . qq(</li>) . "\n";
        for my $myKey ( $h->{'menu'}->[$ind1]->{'applications'} ) {
            # Sort applications with weight
            my @reorderedApps = _sortApps( $h->{'menu'}->[$ind1]->{'applications'}, $weighedApps );


            for(my $ind2=0; $ind2 < @{$myKey}; $ind2 ++) {
                $htmlMenu .= qq(<li>);
                $htmlMenu .= qq(<a href="). $reorderedApps[$ind2]->{'appuri'}. qq(">);
                $htmlMenu .= qq(<img src="). "/skins/common/apps/" . $reorderedApps[$ind2]->{'applogo'}. qq("/>) . $reorderedApps[$ind2]->{'appname'} . qq(</a>) . "\n";
                $htmlMenu .= qq(</li>) . "\n";
            }
        }
        $htmlMenu .= qq(</ul>) . "\n";
    }

    return $htmlMenu;

}

##@fn private string_unbuildSoapAttributes(SOAP::Data)
# Serialize a hashref into SOAP::Data. Types are fixed to "string".
# @return SOAP::Data serialized datas
sub _unbuildSoapAttributes {
    my ( $h, @keys ) = @_;
    my @tmp = ();
    my $htmlMenu = '';

    my $json = $h->{'attributes'}->{'userPreferences'};
    my $decoded_json = decode_json( $json );

    return $decoded_json;

}

1;
