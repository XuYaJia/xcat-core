#!/usr/bin/env perl
# IBM(c) 2010 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT::NetworkUtils;

BEGIN
{
    $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}

# if AIX - make sure we include perl 5.8.2 in INC path.
#       Needed to find perl dependencies shipped in deps tarball.
if ($^O =~ /^aix/i) {
        use lib "/usr/opt/perl5/lib/5.8.2/aix-thread-multi";
        use lib "/usr/opt/perl5/lib/5.8.2";
        use lib "/usr/opt/perl5/lib/site_perl/5.8.2/aix-thread-multi";
        use lib "/usr/opt/perl5/lib/site_perl/5.8.2";
}

use lib "$::XCATROOT/lib/perl";
use POSIX qw(ceil);
use File::Path;
use Math::BigInt;
use Socket;
use strict;
use warnings "all";
my $netipmodule = eval {require Net::IP;};
my $socket6support = eval { require Socket6 };

our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(getipaddr);


#--------------------------------------------------------------------------------

=head1    xCAT::NetworkUtils

=head2    Package Description

This program module file, is a set of network utilities used by xCAT commands.

=cut

#-------------------------------------------------------------


#-------------------------------------------------------------------------------

=head3  gethostnameandip 
    Works for both IPv4 and IPv6.
    Takes either a host name or an IP address string 
    and performs a lookup on that name, 
    returns an array with two elements: the hostname, the ip address
    if the host name or ip address can not be resolved, 
    the corresponding element in the array will be undef
    Arguments:
       hostname or ip address
    Returns: the hostname and the ip address
    Globals:
        
    Error:
        none
    Example:
        my ($host, $ip) = xCAT::NetworkUtils->gethostnameandip($iporhost);
    Comments:
        none
=cut

#-------------------------------------------------------------------------------
sub gethostnameandip()
{
    my ($class, $iporhost) = @_;

    if (($iporhost =~ /\d+\.\d+\.\d+\.\d+/) || ($iporhost =~ /:/)) #ip address
    {
        return (xCAT::NetworkUtils->gethostname($iporhost), $iporhost);
    }
    else #hostname
    {
        return ($iporhost, xCAT::NetworkUtils->getipaddr($iporhost));
    }
}

#-------------------------------------------------------------------------------

=head3  gethostname
    Works for both IPv4 and IPv6.
    Takes an IP address string and performs a lookup on that name,
    returns the hostname of the ip address 
    if the ip address can not be resolved, returns undef
    Arguments:
       ip address
    Returns: the hostname
    Globals:
        cache: %::iphosthash 
    Error:
        none
    Example:
        my $host = xCAT::NetworkUtils->gethostname($ip);
    Comments:
        none
=cut

#-------------------------------------------------------------------------------
sub gethostname()
{
    my ($class, $iporhost) = @_;

    if (!defined($iporhost))
    {
        return undef;
    }

    if (ref($iporhost) eq 'ARRAY')
    {
       $iporhost = @{$iporhost}[0];
       if (!$iporhost)
       {
           return undef;
       }
    }
   
    if (($iporhost !~ /\d+\.\d+\.\d+\.\d+/) && ($iporhost !~ /:/))
    {
        #why you do so? pass in a hostname and only want a hostname??
        return $iporhost;
    }
    #cache, do not lookup DNS each time
    if (defined($::iphosthash{$iporhost}) && $::iphosthash{$iporhost})
    {
        return $::iphosthash{$iporhost};
    }
    else
    {
        if ($socket6support) # the getaddrinfo and getnameinfo supports both IPv4 and IPv6
        {
            my ($family, $socket, $protocol, $ip, $name) = Socket6::getaddrinfo($iporhost,0);
            my $host = (Socket6::getnameinfo($ip))[0];
            if ($host eq $iporhost) # can not resolve
            {
                return undef;
            }
            if ($host)
            {
                $host =~ s/\..*//; #short hostname
            }
            return $host;
        }
        else
        {
            #it is possible that no Socket6 available,
            #but passing in IPv6 address, such as ::1 on loopback
            if ($iporhost =~ /:/)
            {
                return undef;
            }
            my $hostname = gethostbyaddr(inet_aton($iporhost), AF_INET);
            if ( $hostname ) {            
                $hostname =~ s/\..*//; #short hostname
            }
            return $hostname;
        }
     }
}

#-------------------------------------------------------------------------------

=head3  getipaddr
    Works for both IPv4 and IPv6.
    Takes a hostname string and performs a lookup on that name,
    returns the the ip address of the hostname
    if the hostname can not be resolved, returns undef
    Arguments:
       hostname
       Optional:
        GetNumber=>1 (return the address as a BigInt instead of readable string)
    Returns: ip address
    Globals:
        cache: %::hostiphash
    Error:
        none
    Example:
        my $ip = xCAT::NetworkUtils->getipaddr($hostname);                  
    Comments:
        none
=cut

#-------------------------------------------------------------------------------
sub getipaddr
{
    my $iporhost = shift;
    if ($iporhost eq 'xCAT::NetworkUtils') { #was called with -> syntax
        $iporhost = shift;
    }
    my %extraarguments = @_;

   if (!defined($iporhost))
   {
       return undef;
   }

   if (ref($iporhost) eq 'ARRAY')
   {
       $iporhost = @{$iporhost}[0];
       if (!$iporhost)
       {
           return undef;
       }
   }

    #go ahead and do the reverse lookup on ip, useful to 'frontend' aton/pton and also to 
    #spit out a common abbreviation if leading zeroes or using different ipv6 presentation rules
    #if ($iporhost and ($iporhost =~ /\d+\.\d+\.\d+\.\d+/) || ($iporhost =~ /:/))
    #{
    #    #pass in an ip and only want an ip??
    #    return $iporhost;
    #}

    #cache, do not lookup DNS each time
    if ($::hostiphash and defined($::hostiphash{$iporhost}) && $::hostiphash{$iporhost})
    {
        return $::hostiphash{$iporhost};
    }
    else
    {
        if ($socket6support) # the getaddrinfo and getnameinfo supports both IPv4 and IPv6
        {
            my ($family, $socket, $protocol, $ip, $name) = Socket6::getaddrinfo($iporhost,0);
            if ($ip)
            {
                if ($extraarguments{GetNumber}) { #return a BigInt for compare, e.g. for comparing ip addresses for determining if they are in a common network or range
                    my $ip = (Socket6::getnameinfo($ip, Socket6::NI_NUMERICHOST()))[0];
                    my $bignumber = Math::BigInt->new(0);
                    foreach (unpack("N*",Socket6::inet_pton($family,$ip))) { #if ipv4, loop will iterate once, for v6, will go 4 times
                        $bignumber->blsft(32);
                        $bignumber->badd($_);
                    }
                    return $bignumber;
                } else {
                    return (Socket6::getnameinfo($ip, Socket6::NI_NUMERICHOST()))[0];
                }
            }
            return undef;
        }
        else
        {
             #return inet_ntoa(inet_aton($iporhost))
             #TODO, what if no scoket6 support, but passing in a IPv6 hostname?
	     my $packed_ip;
             $iporhost and $packed_ip = inet_aton($iporhost);
             if (!$packed_ip)
             {
                return undef;
             }
             if ($extraarguments{GetNumber}) { #only 32 bits, no for loop needed.
                 return Math::BigInt->new(unpack("N*",$packed_ip));
             }
             return inet_ntoa($packed_ip);
        }
    }
} 

#-------------------------------------------------------------------------------

=head3  linklocaladdr
    Only for IPv6.               
    Takes a mac address, calculate the IPv6 link local address
    Arguments:
       mac address
    Returns:
       ipv6 link local address. returns undef if passed in a invalid mac address
    Globals:
    Error:
        none
    Example:
        my $linklocaladdr = xCAT::NetworkUtils->linklocaladdr($mac);                   
    Comments:
        none
=cut

#-------------------------------------------------------------------------------
sub linklocaladdr {
    my ($class, $mac) = @_;
    $mac = lc($mac);
    my $localprefix = "fe80";

    my ($m1, $m2, $m3, $m6, $m7, $m8);
    # mac address can be 00215EA376B0 or 00:21:5E:A3:76:B0
    if($mac =~ /^([0-9A-Fa-f]{2}).*?([0-9A-Fa-f]{2}).*?([0-9A-Fa-f]{2}).*?([0-9A-Fa-f]{2}).*?([0-9A-Fa-f]{2}).*?([0-9A-Fa-f]{2})$/)
    {
        ($m1, $m2, $m3, $m6, $m7, $m8) = ($1, $2, $3, $4, $5, $6);
    }
    else
    {
        #not a valid mac address
        return undef;
    }
    my ($m4, $m5)  = ("ff","fe");

    #my $bit = (int $m1) & 2;
    #if ($bit) {
    #   $m1 = $m1 - 2;
    #} else {
    #   $m1 = $m1 + 2;
    #}
    $m1 = hex($m1);
    $m1 = $m1 ^ 2;
    $m1 = sprintf("%x", $m1);

    $m1 = $m1 . $m2;
    $m3 = $m3 . $m4;
    $m5 = $m5 . $m6;
    $m7 = $m7 . $m8;

    my $laddr = join ":", $m1, $m3, $m5, $m7;
    $laddr = join "::", $localprefix, $laddr;

    return $laddr;
}


#-------------------------------------------------------------------------------

=head3  ishostinsubnet
    Works for both IPv4 and IPv6.
    Takes an ip address, the netmask and a subnet,
    chcek if the ip address is in the subnet
    Arguments:
       ip address, netmask, subnet
    Returns: 
       1 - if the ip address is in the subnet
       0 - if the ip address is NOT in the subnet
    Globals:
    Error:
        none
    Example:
        if(xCAT::NetworkUtils->ishostinsubnet($ip, $netmask, $subnet);
    Comments:
        none
=cut

#-------------------------------------------------------------------------------
sub ishostinsubnet {
    my ($class, $ip, $mask, $subnet) = @_;
 
    if ($ip =~ /\d+\.\d+\.\d+\.\d+/) {# ipv4 address
       $ip =~ /([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/;
       my $ipnum = ($1<<24)+($2<<16)+($3<<8)+$4;

       $mask =~ /([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/;
       my $masknum = ($1<<24)+($2<<16)+($3<<8)+$4;

       $subnet =~ /([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/;
       my $netnum = ($1<<24)+($2<<16)+($3<<8)+$4;

       if (($ipnum & $masknum) == $netnum) {
          return 1;
       } else {
          return 0;
       }
    } else { # for ipv6
       if ($netipmodule) {
           my $eip = Net::IP::ip_expand_address ($ip,6);
           my $enet = Net::IP::ip_expand_address ($subnet,6);
           my $bmask = Net::IP::ip_get_mask($mask,6);
           my $bip = Net::IP::ip_iptobin($eip,6);
           my $bipnet = $bip & $bmask;
           my $bnet = Net::IP::ip_iptobin($enet,6);
           if (!$bipnet || !$bnet)
           {
               return 0;
           }
           if ($bipnet == $bnet) {
               return 1;
           }
       } # else, can not check without Net::IP module
       return 0; 
    }
}

#-----------------------------------------------------------------------------

=head3 setup_ip_forwarding

    Sets up ip forwarding on localhost

=cut

#-----------------------------------------------------------------------------
sub setup_ip_forwarding
{
    my ($class, $enable)=@_;  
    if (xCAT::Utils->isLinux()) {
	my $conf_file="/etc/sysctl.conf";
	`grep "net.ipv4.ip_forward" $conf_file`;
        if ($? == 0) {
	    `sed -i "s/^net.ipv4.ip_forward = .*/net.ipv4.ip_forward = $enable/" $conf_file`;
 	} else {
	    `echo "net.ipv4.ip_forward = $enable" >> $conf_file`;
	}
	`sysctl -p $conf_file`;
    }
    else
    {    
	`no -o ipforwarding=$enable`;
    }
    return 0;
}

#-------------------------------------------------------------------------------

=head3  prefixtomask
    Convert the IPv6 prefix length(e.g. 64) to the netmask(e.g. ffff:ffff:ffff:ffff:0000:0000:0000:0000).
    Till now, the netmask format ffff:ffff:ffff:: only works for AIX NIM

    Arguments:
       prefix length
    Returns:
       netmask - netmask like ffff:ffff:ffff:ffff:0000:0000:0000:0000 
       0 - if the prefix length is not correct
    Globals:
    Error:
        none
    Example:
        my #netmask = xCAT::NetworkUtils->prefixtomask($prefixlength);
    Comments:
        none
=cut

#-------------------------------------------------------------------------------
sub prefixtomask {
    my ($class, $prefixlength) = @_;

    if (($prefixlength < 1) || ($prefixlength > 128))
    {
        return 0;
    }
    
    # can not do this without Net::IP module
    if (!$netipmodule)
    {
        return 0;
    }

    my $ip = new Net::IP ("fe80::/$prefixlength") or die (Net::IP::Error());

    my $mask = $ip->mask();

    return $mask;

}
1;
