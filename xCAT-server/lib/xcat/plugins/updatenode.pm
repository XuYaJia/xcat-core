#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html

package xCAT_plugin::updatenode;

BEGIN
{
    $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";

use xCAT::Table;
use xCAT::Schema;
use Data::Dumper;
use xCAT::Utils;
use xCAT::InstUtils;
use Getopt::Long;
use xCAT::GlobalDef;
use Sys::Hostname;
use File::Basename;
use xCAT::GlobalDef;
use xCAT_monitoring::monitorctrl;
use Socket;

1;

#-------------------------------------------------------------------------------

=head1  xCAT_plugin:updatenode
=head2    Package Description
  xCAT plug-in module. It handles the updatenode command.
=cut

#------------------------------------------------------------------------------

#--------------------------------------------------------------------------------

=head3   handled_commands
      It returns a list of commands handled by this plugin.
    Arguments:
        none
    Returns:
        a list of commands.
=cut

#------------------------------------------------------------------------------
sub handled_commands
{
    return {
            updatenode     => "updatenode",
            updatenodestat => "updatenode"
            };
}

#-------------------------------------------------------

=head3  preprocess_request
  Check and setup for hierarchy 
=cut

#-------------------------------------------------------
sub preprocess_request
{
    my $request  = shift;
    my $callback = shift;
    $::subreq = shift;
    my $command = $request->{command}->[0];
    if ($request->{_xcatpreprocessed}->[0] == 1) { return [$request]; }

    my @requests = ();

    if ($command eq "updatenode")
    {
        return &preprocess_updatenode($request, $callback, $::subreq);
    }
    elsif ($command eq "updatenodestat")
    {
        return [$request];
    }
    else
    {
        my $rsp = {};
        $rsp->{data}->[0] = "Unsupported command: $command.";
        $callback->($rsp);
        return \@requests;
    }
}

#-----------------------------------------------------------------------------

=head3   process_request
      It processes the updatenode command.
    Arguments:
      request -- a hash table which contains the command name and the arguments.
      callback -- a callback pointer to return the response to.
    Returns:
        0 - for success. The output is returned through the callback pointer.
        1 -  for error. The error messages are returns through the 
							callback pointer.
=cut

#------------------------------------------------------------------------------
sub process_request
{
    my $request  = shift;
    my $callback = shift;
    $::subreq = shift;
    my $command       = $request->{command}->[0];
    my $localhostname = hostname();

    if ($command eq "updatenode")
    {
        return updatenode($request, $callback, $::subreq);
    }
    elsif ($command eq "updatenodestat")
    {
        return updatenodestat($request, $callback);
    }
    else
    {
        my $rsp = {};
        $rsp->{data}->[0] = "$localhostname: Unsupported command: $command.";
        $callback->($rsp);
        return 1;
    }
    return 0;
}

#-----------------------------------------------------------------------------

=head3   preprocess_updatenode
        This function checks for the syntax of the updatenode command
     		and distributes the command to the right server. 
    Arguments:
      request - the request. 
      callback - the pointer to the callback function.
	  subreq - the sub request
    Returns:
      A pointer to an array of requests.
=cut

#------------------------------------------------------------------------------
sub preprocess_updatenode
{
    my $request  = shift;
    my $callback = shift;
    my $subreq   = shift;
    my $args     = $request->{arg};
    my @requests = ();

    my $installdir = xCAT::Utils->getInstallDir();

    # subroutine to display the usage
    sub updatenode_usage
    {
        my $cb  = shift;
        my $rsp = {};
        my $usage_string = xCAT::Usage->getUsage("updatenode");
        push @{$rsp->{data}},$usage_string;

        $cb->($rsp);
    }

    @ARGV = ();
    if ($args)
    {
        @ARGV = @{$args};
    }

    # parse the options
    Getopt::Long::Configure("bundling");
    Getopt::Long::Configure("no_pass_through");
    if (
        !GetOptions(
                    'c|cmdlineonly'    => \$::CMDLINE,
                    'h|help'           => \$::HELP,
                    'v|version'        => \$::VERSION,
                    'V|verbose'        => \$::VERBOSE,
                    'F|sync'           => \$::FILESYNC,
                    'S|sw'             => \$::SWMAINTENANCE,
                    's|sn'             => \$::SETSERVER,
                    'P|scripts:s'      => \$::RERUNPS,
                    'security'         => \$::SECURITY,
                    'user=s'           => \$::USER,
                    'devicetype=s'     => \$::DEVICETYPE,
        )
      )
    {
        &updatenode_usage($callback);
        return \@requests;
    }

    # display the usage if -h or --help is specified
    if ($::HELP)
    {
        &updatenode_usage($callback);
        return \@requests;
    }

    # display the version statement if -v or --verison is specified
    if ($::VERSION)
    {
        my $rsp = {};
        $rsp->{data}->[0] = xCAT::Utils->Version();
        $callback->($rsp);
        return \@requests;
    }

    # -c must work with -S for AIX node
    if ($::CMDLINE && !$::SWMAINTENANCE) {
        &updatenode_usage($callback);
        return \@requests;
    }
    
    # -s must work with -P or -S or --security
    if ($::SETSERVER && !($::SWMAINTENANCE || $::RERUNPS || $::SECURITY)) {
        &updatenode_usage($callback);
        return \@requests;
    }

    # --user and --devicetype must work with --security
    if (($::USER || $::DEVICETYPE) && !($::SECURITY && $::USER && $::DEVICETYPE)) {
        &updatenode_usage($callback);
        return \@requests;
    }

    # --security cannot work with -S -P -F
    if ($::SECURITY && ($::SWMAINTENANCE || $::RERUNPS || defined($::RERUNPS))) {
        &updatenode_usage($callback);
        return \@requests;
    }

    # the -P flag is omitted when only postscritps are specified,
    # so if there are parameters without any flags, it may mean
    # to re-run the postscripts.
    if (@ARGV)
    {

        # we have one or more operands on the cmd line
        if ($#ARGV == 0
            && !($::FILESYNC || $::SWMAINTENANCE || defined($::RERUNPS) || $::SECURIT))
        {

            # there is only one operand
            # if it doesn't contain an = sign then it must be postscripts
            if (!($ARGV[0] =~ /=/))
            {
                $::RERUNPS = $ARGV[0];
                $ARGV[0] = "";
            }
        }
    }
    else
    {

        # no flags and no operands
        if (!($::FILESYNC || $::SWMAINTENANCE || defined($::RERUNPS) ||$::SECURITY))
        {
            $::FILESYNC      = 1;
            $::SWMAINTENANCE = 1;
            $::RERUNPS       = "";
        }
    }

    if ($::SECURITY && !($::USER || $::DEVICETYPE)) {
        $::RERUNPS = "allkeys44444444security";
    }

    my $nodes = $request->{node};
    if (!$nodes)
    {
        &updatenode_usage($callback);
        return \@requests;
    }

    #
    # process @ARGV for the software maintenance of AIX node, it should 
    # be the list of attr=val, put attr=val operands in %attrvals hash
    #

    my %attrvals;
    if ($::SWMAINTENANCE) {
        while (my $a = shift(@ARGV))
        {
            if ($a =~ /=/)
            {
    
                # if it has an "=" sign its an attr=val - we hope
                my ($attr, $value) = $a =~ /^\s*(\S+?)\s*=\s*(\S*.*)$/;
    
                if (!defined($attr) || !defined($value))
                {
                    my $rsp;
                    $rsp->{data}->[0] = "Incorrect \'attr=val\' pair - $a\n";
                    xCAT::MsgUtils->message("E", $rsp, $::callback);
                    return 3;
                }
    
                # put attr=val in hash
                $attrvals{$attr} = $value;
            }
        }
    }

    my @nodes = @$nodes;
    my $postscripts;

    # handle the validity of postscripts 
    if (defined($::RERUNPS))
    {
        if ($::RERUNPS eq "")
        {
            $postscripts = "";
        }
        else
        {
            $postscripts = $::RERUNPS;
            my @posts = ();
            if ($postscripts eq "allkeys44444444security") {
                @posts = ("remoteshell", "aixremoteshell", "servicenode", "xcatserver", "xcatclient");
            } else {
                @posts = split(',', $postscripts);
            }

            foreach (@posts)
            {
                if (!-e "$installdir/postscripts/$_")
                {
                    my $rsp = {};
                    $rsp->{data}->[0] =
                      "The postcript $installdir/postscripts/$_ does not exist.";
                    $callback->($rsp);
                    return \@requests;
                }
            }
        }
    }

    # If -F option specified, sync files to the noderange.
    # Note: This action only happens on MN, since xdcp, xdsh handles the
    #	hierarchical scenario inside
    if ($::FILESYNC)
    {
        my $reqcopy = {%$request};
        $reqcopy->{FileSyncing}->[0] = "yes";
        push @requests, $reqcopy;
    }

    # when specified -S or -P or --security
    # find service nodes for requested nodes
    # build an individual request for each service node
    unless (defined($::SWMAINTENANCE) || defined($::RERUNPS) || $::SECURITY)
    {
        return \@requests;
    }


    my %insttype_node = ();
    # get the nodes installation type
    xCAT::SvrUtils->getNodesetStates($nodes, \%insttype_node);

    
    # figure out the diskless nodes list and non-diskless nodes
    foreach my $type (keys %insttype_node) {
        if ($type eq "netboot" || $type eq "diskless") {
            push @dsklsnodes, @{$insttype_node{$type}};
        } else {
            push @notdsklsnodes, @{$insttype_node{$type}};
        }
    }

    if (defined($::SWMAINTENANCE) && scalar(@dsklsnodes) > 0) {
        my $rsp;
        my $outdsklsnodes = join (',', @dsklsnodes);
        push @{$rsp->{data}}, "updatenode command does not support software maintenance to diskless node. Following diskless nodes will be skipped to perform software maintenance:\n$outdsklsnodes";
        xCAT::MsgUtils->message("E", $rsp, $callback);
    }

    #  - need to consider the mixed cluster case
    #		- can't depend on the os of the MN - need to split out the AIX
    #		nodes from the node list which are not diskless 
    my ($rc, $AIXnodes, $Linuxnodes) = xCAT::InstUtils->getOSnodes(\@notdsklsnodes);
    my @aixnodes = @$AIXnodes;
    
    # for AIX nodes we need to copy software to SNs first - if needed
    my ($rc, $imagedef, $updateinfo);
    if (defined($::SWMAINTENANCE) && scalar(@aixnodes))
    {
        ($rc, $imagedef, $updateinfo) =
          &doAIXcopy($callback, \%attrvals, $AIXnodes, $subreq);
        if ($rc != 0)
        {
            # Do nothing when doAIXcopy failed
            return undef;
        }
    }


    my $sn = xCAT::Utils->get_ServiceNode(\@nodes, "xcat", "MN");
    if ($::ERROR_RC)
    {
        my $rsp;
        push @{$rsp->{data}}, "Could not get list of xCAT service nodes.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return \@requests;

        # return undef; ???
    }


    # for security update, we need to handle the service node first
    my @good_sns = ();
    my @MNip   = xCAT::Utils->determinehostname;
    my @sns = ();
    foreach my $s (keys %$sn) {
        if (!grep (/^$s$/, @MNip)) {
            push @sns, $s;
        }
    }
    if (scalar(@sns) && $::SECURITY) {
        
        $::CALLBACK = $callback;
        $::NODEOUT = ();

        # setup the ssh keys
        my $req_sshkey = {%$request};
        $req_sshkey->{node} = \@sns;
        $req_sshkey->{security}->[0] = "yes";
        if ($::USER) {
            $req_sshkey->{user}->[0] = $::USER;
        }
        if ($::DEVICETYPE) {
            $req_sshkey->{devicetype}->[0] = $::DEVICETYPE;
        }

        updatenode($req_sshkey, \&updatenode_cb, $subreq);

        # run the postscripts: remoteshell, servicenode, xcatserver, xcatclient
        if ($postscripts eq "allkeys44444444security") {
            my ($rc, $AIXnodes, $Linuxnodes) = xCAT::InstUtils->getOSnodes(\@sns);

            my $req_rs = {%$request};
            my $ps;
            if (scalar(@{$AIXnodes})) {
                $ps = "aixremoteshell,servicenode";
                $req_rs->{rerunps}->[0] = "yes";
                $req_rs->{rerunps4security}->[0] = "yes";
                $req_rs->{node} = $AIXnodes;
                $req_rs->{postscripts} = [$ps];
                updatenode($req_rs, \&updatenode_cb, $subreq);
            }
            if (scalar(@{$Linuxnodes})) {
                $ps = "remoteshell,servicenode,xcatserver,xcatclient";
                $req_rs->{rerunps}->[0] = "yes";
                $req_rs->{rerunps4security}->[0] = "yes";
                $req_rs->{node} = $Linuxnodes;
                $req_rs->{postscripts} = [$ps];
                updatenode($req_rs, \&updatenode_cb, $subreq);
            }
        }
        
        # parse the output of update security for sns
        foreach my $sn (keys %{$::NODEOUT}) {
            if (!grep /^$sn$/, @sns) {
                next;
            }
            if ( (grep /ps ok/, @{$::NODEOUT->{$sn}})
             &&  (grep /ssh ok/, @{$::NODEOUT->{$sn}}) ) {
                push @good_sns, $sn;
            }
        }

        if ($::VERBOSE) {
            my $rsp;
            push @{$rsp->{data}}, "Update security for following service nodes: @sns.";
            push @{$rsp->{data}}, "  Following service nodes have been updated successfully: @good_sns";
            xCAT::MsgUtils->message("I", $rsp, $callback);
        }
    }
    
    # build each request for each service node
    foreach my $snkey (keys %$sn)
    {
        if ($::SECURITY
            && !(grep /^$snkey$/, @good_sns)
            && !(grep /^$snkey$/, @MNip)) {
            my $rsp;
            push @{$rsp->{data}}, "The security update for service node $snkey encountered error, update security for following nodes will be skipped: @{$sn->{$snkey}}";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            next;
        }

        # remove the service node which have been handled before
        if ($::SECURITY && (grep /^$snkey$/, @MNip)) {
            delete @{$sn->{$snkey}}[@sns];
            if (scalar(@{$sn->{$snkey}}) == 0) {
                next;
            }
        }
        
        my $reqcopy = {%$request};
        $reqcopy->{node}                   = $sn->{$snkey};
        $reqcopy->{'_xcatdest'}            = $snkey;
        $reqcopy->{_xcatpreprocessed}->[0] = 1;

        if (defined($::SWMAINTENANCE))
        {
            # skip the diskless nodes
            my @validnode = ();
            foreach my $node (@{$sn->{$snkey}}) {
                if (! grep /^$node$/, @dsklsnodes) {
                    push @validnode, $node;
                }
            }
            if (scalar (@validnode) > 0) {
                $reqcopy->{nondsklsnode} = \@validnode;
                $reqcopy->{swmaintenance}->[0] = "yes";
    
                # send along the update info and osimage defs
                if ($imagedef)
                {
                    xCAT::InstUtils->taghash($imagedef);
                    $reqcopy->{imagedef} = [$imagedef];
                }
                if ($updateinfo)
                {
                    xCAT::InstUtils->taghash($updateinfo);
                    $reqcopy->{updateinfo} = [$updateinfo];
                }
            }
        }

        if (defined($::RERUNPS))
        {
            $reqcopy->{rerunps}->[0] = "yes";
            $reqcopy->{postscripts} = [$postscripts];
            if (defined($::SECURITY)) {
                $reqcopy->{rerunps4security}->[0] = "yes";
            }
        }

        if (defined($::SECURITY)) {
            $reqcopy->{security}->[0] = "yes";
            if ($::USER) {
                $reqcopy->{user}->[0] = $::USER;
            }
            if ($::DEVICETYPE) {
                $reqcopy->{devicetype}->[0] = $::DEVICETYPE;
            }
        }

        push @requests, $reqcopy;

    }
    return \@requests;
}


#--------------------------------------------------------------------------------

=head3   updatenode_cb

    A callback function which is used to handle the output of updatenode function
    when run updatenode --secruity for service node inside 

=cut

#-----------------------------------------------------------------------------
sub updatenode_cb
{
    my $resp = shift;

    # call the original callback function
    $::CALLBACK->($resp);

    foreach my $line (@{$resp->{data}}) {
        my $node;
        my $msg;
        if ($line =~ /(.*):(.*)/) {
            $node = $1;
            $msg = $2;
        }
        if ($msg =~ /Redeliver certificates has completed/) {
            push @{$::NODEOUT->{$node}}, "ps ok";
        } elsif ($msg =~ /Setup ssh keys has completed/) {
            push @{$::NODEOUT->{$node}}, "ssh ok";
        }
    }
}


#--------------------------------------------------------------------------------

=head3   updatenode
        This function implements the updatenode command. 
    Arguments:
      request - the request.        
      callback - the pointer to the callback function.
	  subreq - the sub request
    Returns:
        0 - for success. The output is returned through the callback pointer.
        1 - for error. The error messages are returned through the 
				callback pointer.
=cut

#-----------------------------------------------------------------------------
sub updatenode
{
    my $request  = shift;
    my $callback = shift;
    my $subreq   = shift;

    #print Dumper($request);
    my $nodes         = $request->{node};
    my $nondsklsnodes = $request->{nondsklsnode};
    my $localhostname = hostname();

    # in a mixed cluster we could potentially have both AIX and Linux
    #	nodes provided on the command line ????
    my ($rc, $AIXnodes, $Linuxnodes) = xCAT::InstUtils->getOSnodes($nodes);

    my $args = $request->{arg};
    @ARGV = ();
    if ($args)
    {
        @ARGV = @{$args};
    }

    # Lookup Install dir location at this Mangment Node.
    # XXX: Suppose that compute nodes has the same Install dir location.
    my $installdir = xCAT::Utils->getInstallDir();

    # convert the hashes back to the way they were passed in
    my $flatreq = xCAT::InstUtils->restore_request($request, $callback);
    my $imgdefs;
    my $updates;
    if ($flatreq->{imagedef})
    {
        $imgdefs = $flatreq->{imagedef};
    }
    if ($flatreq->{updateinfo})
    {
        $updates = $flatreq->{updateinfo};
    }

    # get the NIM primary server name
    my $nimprime = xCAT::InstUtils->getnimprime();
    chomp $nimprime;

    # parse the options - really just need VERBOSE?
    Getopt::Long::Configure("bundling");
    Getopt::Long::Configure("no_pass_through");
    if (
        !GetOptions(
                    'c|cmdlineonly'   => \$::CMDLINE,
                    'h|help'      => \$::HELP,
                    'v|version'   => \$::VERSION,
                    'V|verbose'   => \$::VERBOSE,
                    'F|sync'      => \$::FILESYNC,
					's|sn'		  => \$::SETSERVER,
                    'S|sw'        => \$::SWMAINTENANCE,
                    'P|scripts:s' => \$::RERUNPS
        )
      )
    {
    }

    #
    # process @ARGV
    #

    #  - put attr=val operands in %::attrres hash
    while (my $a = shift(@ARGV))
    {
        if ($a =~ /=/)
        {

            # if it has an "=" sign its an attr=val - we hope
            my ($attr, $value) = $a =~ /^\s*(\S+?)\s*=\s*(\S*.*)$/;

            if (!defined($attr) || !defined($value))
            {
                my $rsp;
                $rsp->{data}->[0] = "Incorrect \'attr=val\' pair - $a\n";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                return 3;
            }

            # put attr=val in hash
            $::attrres{$attr} = $value;
        }
    }

    #
    #  handle file synchronization
    #

    if ($request->{FileSyncing} && $request->{FileSyncing}->[0] eq "yes")
    {
        my %syncfile_node      = ();
        my %syncfile_rootimage = ();
        my $node_syncfile      = xCAT::SvrUtils->getsynclistfile($nodes);
        foreach my $node (@$nodes)
        {
            my $synclist = $$node_syncfile{$node};

            if ($synclist)
            {
                push @{$syncfile_node{$synclist}}, $node;
            }
        }

        # Check the existence of the synclist file
        foreach my $synclist (keys %syncfile_node)
        {
            if (!(-r $synclist))
            {
                my $rsp = {};
                $rsp->{data}->[0] =
                  "The Synclist file $synclist which specified for certain node does NOT existed.";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }
        }

        # Sync files to the target nodes
        foreach my $synclist (keys %syncfile_node)
        {
            if (defined($::VERBOSE))
            {
                my $rsp = {};
                $rsp->{data}->[0] =
                  "  $localhostname: Internal call command: xdcp -F $synclist";
                $callback->($rsp);
            }
            my $args = ["-F", "$synclist"];
            my $env = ["DSH_RSYNC_FILE=$synclist"];
            $subreq->(
                      {
                       command => ['xdcp'],
                       node    => $syncfile_node{$synclist},
                       arg     => $args,
                       env     => $env
                      },
                      $callback
                      );
        }
        my $rsp = {};
        $rsp->{data}->[0] = "File synchronization has completed.";
        $callback->($rsp);
    }

    if (scalar(@$AIXnodes))
    {
        if (xCAT::Utils->isLinux())
        {
            # mixed cluster enviornment, Linux MN=>AIX node
            # linux nfs client can not mount AIX nfs directory with default settings.
            # settting nfs_use_reserved_ports=1 could solve the problem
            my $cmd   = qq~nfso -o nfs_use_reserved_ports=1~;
            my $output =
              xCAT::InstUtils->xcmd($callback, $subreq, "xdsh", $AIXnodes, $cmd, 0);
            if ($::RUNCMD_RC != 0)
            {
                my $rsp;
                push @{$rsp->{data}},
                  "Could not set nfs_use_reserved_ports=1 on nodes. Error message is:\n";
                push @{$rsp->{data}}, "$output\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }
        }
    }

    #
    #  handle software updates
    #
    if ($request->{swmaintenance} && $request->{swmaintenance}->[0] eq "yes")
    {
        my $rsp;
        push @{$rsp->{data}},
          "Performing software maintenance operations. This could take a while.\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);

        my ($rc, $AIXnodes_nd, $Linuxnodes_nd) = xCAT::InstUtils->getOSnodes($nondsklsnodes);

        if (scalar(@$Linuxnodes_nd))
        {    # we have a list of linux nodes
            my $cmd;
 	    # get server names as known by the nodes
	    my %servernodes = %{xCAT::InstUtils->get_server_nodes($callback, \@$Linuxnodes_nd)};
	    # it's possible that the nodes could have diff server names
	    # do all the nodes for a particular server at once
	    foreach my $snkey (keys %servernodes) {
		my $nodestring = join(',', @{$servernodes{$snkey}});
            	my $cmd;
		if ($::SETSERVER) {
		    $cmd =
		    "XCATBYPASS=Y $::XCATROOT/bin/xdsh $nodestring -s -e $installdir/postscripts/xcatdsklspost 2 -M $snkey otherpkgs 2>&1";

		} else {
		    
		    $cmd =
		    "XCATBYPASS=Y $::XCATROOT/bin/xdsh $nodestring -s -e $installdir/postscripts/xcatdsklspost 2 -m $snkey otherpkgs 2>&1";
		}

		if (defined($::VERBOSE))
		{
		    my $rsp = {};
		    $rsp->{data}->[0] = "  $localhostname: Internal call command: $cmd";
		    $callback->($rsp);
		}
		
		if ($cmd && !open(CMD, "$cmd |"))
		{
		    my $rsp = {};
		    $rsp->{data}->[0] = "$localhostname: Cannot run command $cmd";
		    $callback->($rsp);
		}
		else
		{
		    while (<CMD>)
		    {
			my $rsp    = {};
			my $output = $_;
			chomp($output);
			$output =~ s/\\cM//;
			if ($output =~ /returned from postscript/)
			{
			    $output =~
				s/returned from postscript/Running of Software Maintenance has completed./;
			}
			$rsp->{data}->[0] = "$output";
			$callback->($rsp);
		    }
		    close(CMD);
		}
	    }

        }

        if (scalar(@$AIXnodes_nd))
        {    # we have AIX nodes

            # update the software on an AIX node
            if (
                &updateAIXsoftware(
                                   $callback, $imgdefs, $updates,
                                   $AIXnodes_nd, $subreq
                ) != 0
              )
            {

                #		my $rsp;
                #		push @{$rsp->{data}},  "Could not update software for AIX nodes \'@$AIXnodes\'.";
                #		xCAT::MsgUtils->message("E", $rsp, $callback);;
                return 1;
            }
        }
    }    # end sw maint section

    #
    # handle of setting up ssh keys
    #

    if ($request->{security} && $request->{security}->[0] eq "yes") {
         
        # generate the arguments
        my @args = ("-K");
        if ($request->{user}->[0]) {
            push @args, "--user";
            push @args, $request->{user}->[0];
        }
        if ($request->{devicetype}->[0]) {
            push @args, "--devicetype";
            push @args, $request->{devicetype}->[0];
        }

        # remove the host key from known_hosts
        xCAT::Utils->runxcmd(  {
            command => ['makeknownhosts'],
            node    => \@$nodes,
            arg     => ['-r'],
            }, $subreq, 0, 1);

        if (defined($::VERBOSE))
        {
            my $rsp = {};
            $rsp->{data}->[0] =
              "  $localhostname: run makeknownhosts to clean known_hosts file for nodes: @$nodes";
            $callback->($rsp);
        }

        # call the xdsh -K to set up the ssh keys
        my @envs = @{$request->{environment}};
        my $res = xCAT::Utils->runxcmd(  {
            command => ['xdsh'],
            node    => \@$nodes,
            arg     => \@args,
            env     => \@envs,
            }, $subreq, 0, 1);
            
        if (defined($::VERBOSE))
        {
            my $rsp = {};
            $rsp->{data}->[0] =
              "  $localhostname: Internal call command: xdsh -K. nodes = @$nodes, arguments = @args, env = @envs";
            $rsp->{data}->[1] = 
              "  $localhostname: return messages of last command: @$res";
            $callback->($rsp);
        }

        # parse the output of xdsh -K
        my @failednodes = @$nodes;
        foreach my $line (@$res) {
            chomp($line);
            if ($line =~ /SSH setup failed for the following nodes: (.*)\./) {
                @failednodes = split(/,/, $1);
            } elsif ($line =~ /setup is complete/) {
                @failednodes = ();
            }
        }


        my $rsp = {};
        foreach my $node (@$nodes) {
            if (grep /^$node$/, @failednodes) {
                push @{$rsp->{data}}, "$node: Setup ssh keys failed.";
            } else {
                push @{$rsp->{data}}, "$node: Setup ssh keys has completed.";
            }
        }
        $callback->($rsp);
    }

    #
    # handle the running of cust scripts
    #

    if ($request->{rerunps} && $request->{rerunps}->[0] eq "yes")
    {
        my $postscripts = "";
        my $orig_postscripts = "";
        if (($request->{postscripts}) && ($request->{postscripts}->[0]))
        {
            $orig_postscripts = $request->{postscripts}->[0];
        }

        if (scalar(@$Linuxnodes))
        {    
           if ($orig_postscripts eq "allkeys44444444security") {
               $postscripts = "remoteshell,servicenode,xcatserver,xcatclient";
           } else {
               $postscripts = $orig_postscripts;
           }
           
           # we have Linux nodes
           my $cmd;
	    # get server names as known by the nodes
	    my %servernodes = %{xCAT::InstUtils->get_server_nodes($callback, \@$Linuxnodes)};
	    # it's possible that the nodes could have diff server names
	    # do all the nodes for a particular server at once
	    foreach my $snkey (keys %servernodes) {
		my $nodestring = join(',', @{$servernodes{$snkey}});
            	my $cmd;
                my $mode;
                if ($request->{rerunps4security} && $request->{rerunps4security}->[0] eq "yes") {
                    # for updatenode --security
                    $mode = "5";
                } else {
                    # for updatenode -P
                    $mode = "1"; 
                }
		if ($::SETSERVER) {
		    $cmd =
		    "XCATBYPASS=Y $::XCATROOT/bin/xdsh $nodestring -s -e $installdir/postscripts/xcatdsklspost $mode -M $snkey $postscripts 2>&1";

		} else {
		    
		    $cmd =
		    "XCATBYPASS=Y $::XCATROOT/bin/xdsh $nodestring -s -e $installdir/postscripts/xcatdsklspost $mode -m $snkey $postscripts 2>&1";
		}
		

		if (defined($::VERBOSE))
		{
		    my $rsp = {};
		    $rsp->{data}->[0] = "  $localhostname: Internal call command: $cmd";
		    $callback->($rsp);
		}
		
		if (!open(CMD, "$cmd |"))
		{
		    my $rsp = {};
		    $rsp->{data}->[0] = "$localhostname: Cannot run command $cmd";
		    $callback->($rsp);
		}
		else
		{
                    my $rsp    = {};
		    while (<CMD>)
		    {
			my $output = $_;
			chomp($output);
			$output =~ s/\\cM//;
			if ($output =~ /returned from postscript/)
			{
			    $output =~
				s/returned from postscript/Running of postscripts has completed./;
			}
                        if ($request->{rerunps4security} && $request->{rerunps4security}->[0] eq "yes") {
                            if ($output =~ /Running of postscripts has completed/) {
                                $output =~ s/Running of postscripts has completed/Redeliver certificates has completed/;
                                push @{$rsp->{data}}, $output;
                            } elsif ($output !~ /Running postscript|Error loading module/) {
			        push @{$rsp->{data}}, "$output";
                            }
                        } else {
			    push @{$rsp->{data}}, "$output";
                        }
		    }
		    close(CMD);
                    $callback->($rsp);
		}
	    }
        }

        if (scalar(@$AIXnodes))
        {
           # we have AIX nodes
           if ($orig_postscripts eq "allkeys44444444security") {
               $postscripts = "aixremoteshell,servicenode";
           } else {
               $postscripts = $orig_postscripts;
           }
           
	    # need to pass the name of the server on the xcataixpost cmd line
	    
	    # get server names as known by the nodes
	    my %servernodes = %{xCAT::InstUtils->get_server_nodes($callback, \@$AIXnodes)};
	    # it's possible that the nodes could have diff server names
	    # do all the nodes for a particular server at once
	    foreach my $snkey (keys %servernodes) {
		$nodestring = join(',', @{$servernodes{$snkey}});
            	my $cmd;
                my $mode;
                if ($request->{rerunps4security} && $request->{rerunps4security}->[0] eq "yes") {
                    # for updatenode --security
                    $mode = "5";
                } else {
                    # for updatenode -P
                    $mode = "1";
                }

		if ($::SETSERVER) {
		    $cmd = "XCATBYPASS=Y $::XCATROOT/bin/xdsh $nodestring -s -e $installdir/postscripts/xcataixpost -M $snkey -c $mode $postscripts 2>&1";
		} else {
		    $cmd = "XCATBYPASS=Y $::XCATROOT/bin/xdsh $nodestring -s -e $installdir/postscripts/xcataixpost -m $snkey -c $mode $postscripts 2>&1";
		}
		
            	if (defined($::VERBOSE))
            	{
		    my $rsp = {};
		    $rsp->{data}->[0] = "  $localhostname: Internal call command: $cmd";
		    $callback->($rsp);
            	}
		
            	if (!open(CMD, "$cmd |"))
            	{
		    my $rsp = {};
		    $rsp->{data}->[0] = "$localhostname: Cannot run command $cmd";
		    $callback->($rsp);
            	}
            	else
            	{
                    my $rsp = {};
		    while (<CMD>)
		    {
                    	my $output = $_;
                    	chomp($output);
                    	$output =~ s/\\cM//;
                    	if ($output =~ /returned from postscript/)
                    	{
			    $output =~
				s/returned from postscript/Running of postscripts has completed./;
                    	}
                        if ($request->{rerunps4security} && $request->{rerunps4security}->[0] eq "yes") {
                            if ($output =~ /Running of postscripts has completed/) {
                                $output =~ s/Running of postscripts has completed/Redeliver certificates has completed/;
                                push @{$rsp->{data}}, $output;
                            } elsif ($output !~ /Running postscript|Error loading module/) {
                                push @{$rsp->{data}}, $output;
                            }
                        } else {
			    push @{$rsp->{data}}, "$output";
                        }
		    }
		    close(CMD);
                    $callback->($rsp);
            	}
	    }
        }
        if ($request->{rerunps4security} && $request->{rerunps4security}->[0] eq "yes") {
            # clean the know_hosts
            xCAT::Utils->runxcmd(  {
                command => ['makeknownhosts'],
                node    => \@$nodes,
                arg     => ['-r'],
                }, $subreq, 0, 1);
        }
    }


    return 0;
}

sub updatenodestat
{
    my $request  = shift;
    my $callback = shift;
    my @nodes    = ();
    my @args     = ();
    if (ref($request->{node}))
    {
        @nodes = @{$request->{node}};
    }
    else
    {
        if ($request->{node}) { @nodes = ($request->{node}); }
    }
    if (ref($request->{arg}))
    {
        @args = @{$request->{arg}};
    }
    else
    {
        @args = ($request->{arg});
    }

    if ((@nodes > 0) && (@args > 0))
    {
        my %node_status = ();
        my $stat        = $args[0];
        $node_status{$stat} = [];
        foreach my $node (@nodes)
        {
            my $pa = $node_status{$stat};
            push(@$pa, $node);
        }
        xCAT_monitoring::monitorctrl::setNodeStatusAttributes(\%node_status, 1);
    }

    return 0;
}

#-------------------------------------------------------------------------------

=head3   doAIXcopy

    Copy software update files to SNs - if needed.

    Arguments:

    Returns:
		errors:
      		0 - OK
      		1 - error
		hash refs:
			- osimage definitions
			- node update information

    Example
	 my ($rc, $imagedef, $updateinfo) = &doAIXcopy($callback, \%attrvals, 
			$nodes, $subreq);

    Comments:
        - running on MN

=cut

#------------------------------------------------------------------------------
sub doAIXcopy
{
    my $callback = shift;
    my $av       = shift;
    my $nodes    = shift;
    my $subreq   = shift;

    my @nodelist;    # node list
    my %attrvals;    # cmd line attr=val pairs

    if ($nodes)
    {
        @nodelist = @$nodes;
    }

    if ($av)
    {
        %attrvals = %{$av};
    }

    # get the NIM primary server name
    my $nimprime = xCAT::InstUtils->getnimprime();
    chomp $nimprime;

    my %nodeupdateinfo;

    #
    # do we have to copy files to any SNs????
    #

    # get a list of service nodes for this node list
    my $sn = xCAT::Utils->get_ServiceNode(\@nodelist, "xcat", "MN");
    if ($::ERROR_RC)
    {
        my $rsp;
        push @{$rsp->{data}}, "Could not get list of xCAT service nodes.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

    # want list of remote service nodes - to copy files to

    # get the servicenode ip
    my $ip = inet_ntoa(inet_aton($nimprime));
    chomp $ip;
    my ($p1, $p2, $p3, $p4) = split /\./, $ip;

    my @SNlist;
    foreach my $snkey (keys %$sn)
    {

        my $ip = inet_ntoa(inet_aton($snkey));
        chomp $ip;
        my ($s1, $s2, $s3, $s4) = split /\./, $ip;
        if (($s1 == $p1) && ($s2 == $p2) && ($s3 == $p3) && ($s4 == $p4))
        {
            next;
        }
        else
        {
            if (!grep(/^$snkey$/, @SNlist))
            {
                push(@SNlist, $snkey);
            }
        }
    }

    # get a list of osimage names needed for the nodes
    my $nodetab = xCAT::Table->new('nodetype');
    my $images  =
      $nodetab->getNodesAttribs(\@nodelist, ['node', 'provmethod', 'profile']);
    my @imagenames;
    foreach my $node (@nodelist)
    {
        my $imgname;
        if ($images->{$node}->[0]->{provmethod})
        {
            $imgname = $images->{$node}->[0]->{provmethod};
        }
        elsif ($images->{$node}->[0]->{profile})
        {
            $imgname = $images->{$node}->[0]->{profile};
        }
        if (!grep(/^$imgname$/, @imagenames))
        {
            push @imagenames, $imgname;
        }
        $nodeupdateinfo{$node}{imagename} = $imgname;
    }
    $nodetab->close;

    my $osimageonly = 0;
    if ((!$attrvals{installp_bundle} && !$attrvals{otherpkgs}) && !$::CMDLINE)
    {

        # if nothing is provided on the cmd line and we don't set CMDLINE
        #	then we just use
        #   the osimage def - used for permanent updates - saved
        #   in the osimage def
        $osimageonly = 1;
    }

    #
    #  get the osimage defs
    #
    my %imagedef;
    my @pkglist;    # list of all software to go to SNs
    my %bndloc;

    foreach $img (@imagenames)
    {
        my %objtype;
        $objtype{$img} = 'osimage';
        %imagedef = xCAT::DBobjUtils->getobjdefs(\%objtype, $callback);
        if (!defined(%imagedef))
        {
            my $rsp;
            push @{$rsp->{data}},
              "Could not get the xCAT osimage definition for \'$img\'.\n";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }

        #
        #  if this is not a "standalone" type image then this is an error
        #
        if ($imagedef{$img}{nimtype} ne "standalone")
        {
            my $rsp;
            push @{$rsp->{data}},
              "The osimage \'$img\' is not a standalone type.  \nThe software maintenance function of updatenode command can only be used for standalone (diskfull) type nodes. \nUse the mknimimage comamand to update diskless osimages.";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }

        if ($osimageonly != 1)
        {

            # get packages from cmd line
            if ($attrvals{installp_bundle})
            {
                $imagedef{$img}{installp_bundle} = $attrvals{installp_bundle};
            }
            else
            {
                $imagedef{$img}{installp_bundle} = "";
            }
            if ($attrvals{otherpkgs})
            {
                $imagedef{$img}{otherpkgs} = $attrvals{otherpkgs};
            }
            else
            {
                $imagedef{$img}{otherpkgs} = "";
            }
        }

        if ($attrvals{installp_flags})
        {
            $imagedef{$img}{installp_flags} = $attrvals{installp_flags};
        }

        if ($attrvals{rpm_flags})
        {
            $imagedef{$img}{rpm_flags} = $attrvals{rpm_flags};
        }

        # get loc of lpp for node
        $imagedef{$img}{lpp_loc} =
          xCAT::InstUtils->get_nim_attr_val($imagedef{$img}{lpp_source},
                                     'location', $callback, $nimprime, $subreq);

        # keep a list of packages from otherpkgs and bndls
        if ($imagedef{$img}{otherpkgs})
        {
            foreach $pkg (split(/,/, $imagedef{$img}{otherpkgs}))
            {
                if (!grep(/^$&pkg$/, @pkglist))
                {
                    push(@pkglist, $pkg);
                }
            }
        }
        if ($imagedef{$img}{installp_bundle})
        {
            my @bndlist = split(/,/, $imagedef{$img}{installp_bundle});
            foreach my $bnd (@bndlist)
            {
                my ($rc, $list, $loc) =
                  xCAT::InstUtils->readBNDfile($callback, $bnd, $nimprime,
                                               $subreq);
                foreach my $pkg (@$list)
                {
                    chomp $pkg;
                    if (!grep(/^$&pkg$/, @pkglist))
                    {
                        push(@pkglist, $pkg);
                    }
                }
                $bndloc{$bnd} = $loc;
            }
        }

        # put array in string to pass along to SN
        $imagedef{$img}{pkglist} = join(',', @pkglist);
    }

    # if there are no SNs to update then return
    if (scalar(@SNlist) == 0)
    {
        return (0, \%imagedef, \%nodeupdateinfo);
    }

    # copy otherpkgs from lpp location on nim prime to same loc on SN
    foreach my $snkey (@SNlist)
    {

        # copy files to SN from nimprime!!
        #  TODO - need to handle xdsh to nimprime to do xdcp to SN?????
        # for now - assume nimprime is management node

        foreach my $img (@imagenames)
        {

            # if lpp_source is not defined on SN then next
            my $scmd =
              qq~/usr/sbin/lsnim -l $imagedef{$img}{lpp_source} 2>/dev/null~;
            my $out =
              xCAT::InstUtils->xcmd($callback, $subreq, "xdsh", $snkey, $scmd,
                                    0);

            if ($::RUNCMD_RC != 0)
            {
                next;
            }

            my $rpm_srcdir   = "$imagedef{$img}{lpp_loc}/RPMS/ppc";
            my $instp_srcdir = "$imagedef{$img}{lpp_loc}/installp/ppc";

            # copy  all the packages
            foreach my $pkg (@pkglist)
            {
                my $rcpargs;
                my $srcfile;
                if (($pkg =~ /R:/))
                {
                    my ($junk, $pname) = split(/:/, $pkg);

                    # use rpm location
                    $rcpargs = ["$rpm_srcdir/$pname", "$rpm_srcdir"];
                }
                else
                {
                    my $pname;
                    my $junk;
                    if ($pkg =~ /:/)
                    {
                        ($junk, $pname) = split(/:/, $pkg);
                    }
                    else
                    {
                        $pname = $pkg;
                    }

                    # use installp loc
                    my @allfiles = glob "$instp_srcdir/$pname*";
                    my $sourcefiles = "";
                    foreach my $file (@allfiles) {
                        $sourcefiles .= "$file ";	
                    }
                    $rcpargs = [$sourcefiles, "$instp_srcdir"];

                }

                my  $output = xCAT::Utils->runxcmd({command => ["xdcp"],
                                    node => [$snkey], arg => $rcpargs}, $subreq, -1, 0);

                if ($::RUNCMD_RC != 0)
                {
                    my $rsp;
                    push @{$rsp->{data}}, "Could not copy $pkg to $snkey.\n";
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                }
            }
        }

    }    # end - for each service node
    return (0, \%imagedef, \%nodeupdateinfo);
}

#-------------------------------------------------------------------------------

=head3   updateAIXsoftware

    Update the software on an xCAT AIX cluster node. 

    Arguments:

    Returns:
      0 - OK
      1 - error

	Example
		if (&updateAIXsoftware($callback, \%attrres, \%updates, $nodes, $subreq)!= 0) 

    Comments:
		- running on MN or SNs

=cut

#-------------------------------------------------------------------------------

sub updateAIXsoftware
{
    my $callback = shift;
    my $imgdefs  = shift;
    my $updates  = shift;
    my $nodes    = shift;
    my $subreq   = shift;

    my @noderange = @$nodes;
    my %attrvals;    # cmd line attr=val pairs
    my @pkglist;     # list of ALL software to install

    # att=val - bndls, otherpakgs, flags
    if ($attrs)
    {
        %attrvals = %{$attrs};
    }
    if ($imgdefs)
    {
        %imagedefs = %{$imgdefs};
    }
    if ($updates)
    {
        %nodeupdateinfo = %{$updates};
    }

    my %bndloc;

    #
    # get the server name for each node - as known by node
    #
    my $noderestab  = xCAT::Table->new('noderes');
    my $xcatmasters =
      $noderestab->getNodesAttribs(\@noderange, ['node', 'xcatmaster']);

    # get the NIM primary server name
    my $nimprime = xCAT::InstUtils->getnimprime();
    chomp $nimprime;

    # if it's not the xcatmaster then default to the NIM primary
    my %server;
    my @servers;
    foreach my $node (@noderange)
    {
        if ($xcatmasters->{$node}->[0]->{xcatmaster})
        {
            $server{$node} = $xcatmasters->{$node}->[0]->{xcatmaster};
        }
        else
        {
            $server{$node} = $nimprime;
        }

        if (!grep($server{$node}, @servers))
        {
            push(@servers, $server{$node});
        }
    }
    $noderestab->close;

    # sort nodes by image name so we can do bunch at a time
    my %nodeoslist;
    foreach my $node (@noderange)
    {
        foreach my $serv (@servers)
        {
            push(@{$nodeoslist{$nodeupdateinfo{$node}{imagename}}}, $node);
        }
    }

    my $error = 0;
    my @installp_files;    # list of tmp installp files created
    foreach my $img (keys %imagedefs)
    {
		my $noinstallp=0;
        chomp $img;
        if ($img)
        {
            my @nodes = @{$nodeoslist{$img}};

            # process the package list
            #   - split into rpm and installp
            #   - remove leading prefix - if any
            my @rpm_pkgs;
            my @installp_pkgs;
            my @pkglist = split(/,/, $imagedefs{$img}{pkglist});
            if (scalar(@pkglist))
            {
                foreach my $p (@pkglist)
                {
                    if (($p =~ /R:/))
                    {
                        my ($junk, $pname) = split(/:/, $p);
                        push @rpm_pkgs, $pname;
                    }
                    else
                    {
                        my $pname;
                        my $junk;
                        if ($p =~ /:/)
                        {
                            ($junk, $pname) = split(/:/, $p);
                        }
                        else
                        {
                            $pname = $p;
                        }
                        push @installp_pkgs, $pname;
                    }
                }
            }

            #
            # create tmp file for installp
            #
            my $thisdate           = `date +%s`;
            my $installp_file_name = "installp_file-" . $thisdate;
            chomp $installp_file_name;
            if (scalar(@installp_pkgs))
            {
                unless (open(INSTPFILE, ">/tmp/$installp_file_name"))
                {
                    my $rsp;
                    push @{$rsp->{data}},
                      "Could not open $installp_file_name.\n";
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                    return 1;
                }
            }
            foreach (@installp_pkgs)
            {
                print INSTPFILE $_ . "\n";
            }
            close(INSTPFILE);

            # add new file to list so it can be removed later
            push @installp_files, $installp_file_name;

            #
            # copy file to each lpp_source, make sure it's all readable
            #	 and export the lpp_source dir
            #

            if ((-e "/tmp/$installp_file_name"))
            {
                my $icmd =
                  qq~cp /tmp/$installp_file_name $imagedefs{$img}{lpp_loc}~;
                my $output = xCAT::Utils->runcmd("$icmd", -1);
                if ($::RUNCMD_RC != 0)
                {
                    my $rsp;
                    push @{$rsp->{data}},
                      "Could not copy /tmp/$installp_file_name.\n";
                    push @{$rsp->{data}}, "$output\n";
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                    return 1;
                }
            }

            my $chcmd = qq~cd $imagedefs{$img}{lpp_loc}; chmod -R +r *~;
            my $output = xCAT::Utils->runcmd("$chcmd", -1);
            if ($::RUNCMD_RC != 0)
            {
                my $rsp;
                push @{$rsp->{data}}, "Could not chmod $lpp.\n";
                push @{$rsp->{data}}, "$output\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }

            my $ecmd = qq~exportfs -i $imagedefs{$img}{lpp_loc}~;
            my $output = xCAT::Utils->runcmd("$ecmd", -1);
            if ($::RUNCMD_RC != 0)
            {
                my $rsp;
                push @{$rsp->{data}}, "Could not export $lpp.\n";
                push @{$rsp->{data}}, "$output\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }

            #
            # install sw on nodes
            #
			# $serv is the name of the nodes server as known by the node
            foreach my $serv (@servers)
            {

                # mount lpp dir to node
                my $mcmd   = qq~mount $serv:$imagedefs{$img}{lpp_loc} /mnt~;
                my $output =
                  xCAT::InstUtils->xcmd($callback, $subreq, "xdsh", \@nodes,
                                        $mcmd, 0);
                if ($::RUNCMD_RC != 0)
                {
                    my $rsp;
                    push @{$rsp->{data}},
                      "Could not mount $imagedefs{$img}{lpp_loc} on nodes.\n";
                    push @{$rsp->{data}}, "$output\n";
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                    $error++;
                    next;
                }
            }

            # do installp first
            # if we have installp filesets or other installp flags
			# we may just get flags!
            if (   (scalar(@installp_pkgs))
                || ($imagedefs{$img}{installp_flags}))
            {

                # - use installp with file
                # set flags
                my $flags;
                if ($imagedefs{$img}{installp_flags})
                {
                    $flags = " " . $imagedefs{$img}{installp_flags};
                }
                else
                {
                    $flags = " -agQX ";
                }

                # put together the installp command
                my $inpcmd = qq~/usr/sbin/installp ~;

                # these installp flags can be used with -d
                if ($flags =~ /l|L|i|A|a/)
                {
                    $inpcmd .= qq~-d /mnt ~;
                }

                $inpcmd .= qq~$flags ~;

                # don't provide a list of filesets with these flags
                if ($flags !~ /C|L|l/)
                {
					if ( scalar(@installp_pkgs) == 0  ) {
						$noinstallp=1;
					} else {
                    	$inpcmd .= qq~-f /mnt/$installp_file_name~;
					}
                }

				#  - could just have installp flags by mistake -ugh!
				#	- but don't have fileset to install - so don't run
				#		installp - UNLESS the flags don't need filesets
			  	if ($noinstallp == 0 ) {

                	if ($::VERBOSE)
                	{
                    	my $rsp;
                    	push @{$rsp->{data}}, "Running: \'$inpcmd\'.\n";
                    	xCAT::MsgUtils->message("I", $rsp, $callback);
                	}

                	my @output =
                  	xCAT::InstUtils->xcmd($callback, $subreq, "xdsh", \@nodes,
                                        $inpcmd, 1);
                	if ($::RUNCMD_RC != 0)
                 	{
                    	my $rsp;
                    	push @{$rsp->{data}}, "Could not run installp command.\n";
                    	foreach my $o (@output)
                    	{
                        	push @{$rsp->{data}}, "$o";
                    	}
                    	xCAT::MsgUtils->message("I", $rsp, $callback);
                    	$error++;
                    	next;
                	}
                	if ($::VERBOSE)
                	{
                    	my $rsp;
                    	foreach my $o (@output)
                    	{
                        	push @{$rsp->{data}}, "$o";
                    	}
                    	xCAT::MsgUtils->message("I", $rsp, $callback);
                	}
			  	}
            }

            # - run updtvpkg to make sure installp software
            #		is registered with rpm
            my $ucmd   = qq~/usr/sbin/updtvpkg~;
            my $output =
              xCAT::InstUtils->xcmd($callback, $subreq, "xdsh", \@nodes, $ucmd,
                                    0);
            if ($::RUNCMD_RC != 0)
            {
                my $rsp;
                push @{$rsp->{data}}, "Could not run updtvpkg.\n";
                push @{$rsp->{data}}, "$output\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                next;
            }

			# we may just get rpm flags!
            if (scalar(@rpm_pkgs) || ($imagedefs{$img}{rpm_flags}))
            {

                # don't do rpms if these installp flags were specified
                if ($imagedefs{$img}{installp_flags} !~ /C|L|l/)
                {

                    # set flags
                    my $flags;
                    if ($imagedefs{$img}{rpm_flags})
                    {
                        $flags = " " . $imagedefs{$img}{rpm_flags};
                    }
                    else
                    {
                        $flags = " -Uvh --replacepkgs ";
                    }

                    my $pkg_string = "";
                    foreach my $pkg (@rpm_pkgs)
                    {
                        $pkg_string .= " /mnt/RPMS/ppc/$pkg";
                    }

					my $rcmd;
					$rcmd = qq~rpm $flags $pkg_string~;

                    if ($::VERBOSE)
                    {
                        my $rsp;
                        push @{$rsp->{data}}, "Running: \'$rcmd\'.\n";
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                    }

                    my @output =
                      xCAT::InstUtils->xcmd($callback, $subreq, "xdsh", \@nodes,
                                            $rcmd, 1);
                    if ($::RUNCMD_RC != 0)
                    {
                        my $rsp;
                        push @{$rsp->{data}}, "Could not install RPMs.\n";
                        foreach my $o (@output)
                        {
                            push @{$rsp->{data}}, "$o";
                        }
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                        $error++;
                        next;
                    }
                    if ($::VERBOSE)
                    {
                        my $rsp;
                        foreach my $o (@output)
                        {
                            push @{$rsp->{data}}, "$o";
                        }
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                    }
                }
            }

            # unmount the lpp dir -
            my $ucmd   = qq~umount -f /mnt~;
            my $output =
              xCAT::InstUtils->xcmd($callback, $subreq, "xdsh", \@nodes, $ucmd,
                                    0);
            if ($::RUNCMD_RC != 0)
            {
                my $rsp;
                push @{$rsp->{data}}, "Could not umount.\n";
                if ($::VERBOSE)
                {
                    push @{$rsp->{data}}, "$output\n";
                }
                xCAT::MsgUtils->message("E", $rsp, $callback);
                next;
            }
        }
    }

    # clean up files copied to lpp_source locations and
    #	unexport the lpp locations
    foreach my $img (keys %imagedefs)
    {
        chomp $img;

        foreach $file (@installp_files)
        {
			my $rcmd;
			if ($file =~ /installp_file/) {
				$rcmd = qq~rm -f /tmp/$file~;
			} else {
            	$rcmd = qq~rm -f $imagedefs{$img}{lpp_loc}/$file; rm -f /tmp/$file~;
			}

            my $output = xCAT::Utils->runcmd("$rcmd", -1);

            if ($::RUNCMD_RC != 0)
            {
                my $rsp;
                push @{$rsp->{data}},
                  "Could not remove $imagedefs{$img}{lpp_loc}/$file.\n";
                if ($::VERBOSE)
                {
                    push @{$rsp->{data}}, "$output\n";
                }
                xCAT::MsgUtils->message("E", $rsp, $callback);
                next;
            }
        }

        # unexport lpp dirs????
        my $ucmd = qq~exportfs -u -F $imagedefs{$img}{lpp_loc}~;
        my $output = xCAT::Utils->runcmd("$ucmd", -1);
        if ($::RUNCMD_RC != 0)
        {
            my $rsp;
            push @{$rsp->{data}},
              "Could not unexport $imagedefs{$img}{lpp_loc}.\n";
            if ($::VERBOSE)
            {
                push @{$rsp->{data}}, "$output\n";
            }
            xCAT::MsgUtils->message("E", $rsp, $callback);
            next;
        }
    }

    if ($error)
    {
        my $rsp;
        push @{$rsp->{data}},
          "One or more errors occured while updating node software.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }
    else
    {
        my $rsp;
        push @{$rsp->{data}},
          "Cluster node software update commands have completed successfully.\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }
    return 0;
}

