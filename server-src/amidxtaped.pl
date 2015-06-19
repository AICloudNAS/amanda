#! @PERL@
# Copyright (c) 2010-2012 Zmanda, Inc.  All Rights Reserved.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
# for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
#
# Contact information: Zmanda Inc., 465 S. Mathilda Ave., Suite 300
# Sunnyvale, CA 94086, USA, or: http://www.zmanda.com

use lib '@amperldir@';
use strict;
use warnings;

##
# Interactivity class

package Amanda::Interactivity::amidxtaped;
use base 'Amanda::Interactivity';
use Amanda::Util qw( weaken_ref );
use Amanda::MainLoop;
use Amanda::Feature;
use Amanda::Debug qw( debug );
use Amanda::Config qw( :getconf );
use Amanda::Recovery::Scan qw( $DEFAULT_CHANGER );

sub new {
    my $class = shift;
    my %params = @_;

    my $self = {
	clientservice => $params{'clientservice'},
    };

    # (weak ref here to eliminate reference loop)
    weaken_ref($self->{'clientservice'});

    return bless ($self, $class);
}

sub abort() {
    my $self = shift;

    debug("ignoring spurious Amanda::Recovery::Scan abort call");
}

sub user_request {
    my $self = shift;
    my %params = @_;
    my $buffer = "";

    my $steps = define_steps
	cb_ref => \$params{'request_cb'};

    step send_message => sub {
	if ($params{'err'}) {
	    $self->{'clientservice'}->sendmessage("$params{err}");
	}

	$steps->{'check_fe_feedme'}->();
    };

    step check_fe_feedme => sub {
	# note that fe_amrecover_FEEDME implies fe_amrecover_splits
	if (!$self->{'clientservice'}->{'their_features'}->has(
				    $Amanda::Feature::fe_amrecover_FEEDME)) {
	    return $params{'request_cb'}->("remote cannot prompt for volumes", undef);
	}
	$steps->{'send_feedme'}->();
    };

    step send_feedme => sub {
	$self->{'clientservice'}->sendctlline("FEEDME $params{label}\r\n", $steps->{'read_response'});
    };

    step read_response => sub {
	my ($err, $written) = @_;
	return $params{'request_cb'}->($err, undef) if $err;

	$self->{'clientservice'}->getline_async(
		$self->{'clientservice'}->{'ctl_stream'}, $steps->{'got_response'});
    };

    step got_response => sub {
	my ($err, $line) = @_;
	return $params{'request_cb'}->($err, undef) if $err;

	if ($line eq "OK\r\n") {
	    return $params{'request_cb'}->(undef, undef); # carry on as you were
	} elsif ($line =~ /^TAPE (.*)\r\n$/) {
	    my $tape = $1;
	    if ($tape eq getconf($CNF_AMRECOVER_CHANGER)) {
		$tape = $Amanda::Recovery::Scan::DEFAULT_CHANGER;
	    }
	    return $params{'request_cb'}->(undef, $tape); # use this device
	} else {
	    return $params{'request_cb'}->("got invalid response from remote", undef);
	}
    };
};

##
# ClientService class

package amidxtaped;
use vars qw( @ISA );
use Amanda::ClientService;
use Amanda::Recovery::Clerk;
@ISA = qw( Amanda::ClientService Amanda::Recovery::Clerk::Feedback);

use Sys::Hostname;

use Amanda::Debug qw( debug info warning );
use Amanda::MainLoop qw( :GIOCondition );
use Amanda::Util qw( :constants match_disk match_host );
use Amanda::Feature;
use Amanda::Config qw( :init :getconf );
use Amanda::Storage;
use Amanda::Changer;
use Amanda::Recovery::Scan;
use Amanda::Xfer qw( :constants );
use Amanda::Cmdline;
use Amanda::Recovery::Clerk;
use Amanda::Recovery::Planner;
use Amanda::Recovery::Scan;
use Amanda::DB::Catalog;
use Amanda::Disklist;
use Amanda::FetchDump;

# Note that this class performs its control IO synchronously.  This is adequate
# for this service, as it never receives unsolicited input from the remote
# system.

sub run {
    my $self = shift;

    $self->{'my_features'} = Amanda::Feature::Set->mine();
    $self->{'their_features'} = Amanda::Feature::Set->old();
    $self->{'all_filter'} = {};

    $self->setup_streams();
}

sub set_feedback {
}

sub user_message {
    my $self = shift;
    my $message = shift;

    debug("$message");
}

sub setup_streams {
    my $self = shift;

    # get started checking security for inetd or processing the REQ/REP
    # for amandad
    if ($self->from_inetd()) {
	if (!$self->check_inetd_security('main')) {
	    $main::exit_status = 1;
	    return $self->quit();
	}
	$self->{'ctl_stream'} = 'main';
	$self->{'data_stream'} = undef; # no data stream yet
	$self->{'state_stream'} = undef; # no state stream yet
    } else {
	my $req = $self->get_req();

	# make some sanity checks
	my $errors = [];
	if (defined $req->{'options'}{'auth'} and defined $self->amandad_auth()
		and $req->{'options'}{'auth'} ne $self->amandad_auth()) {
	    my $reqauth = $req->{'options'}{'auth'};
	    my $amauth = $self->amandad_auth();
	    push @$errors, "recover program requested auth '$reqauth', " .
			   "but amandad is using auth '$amauth'";
	    $main::exit_status = 1;
	}

	# and pull out the features, if given
	if (defined($req->{'features'})) {
	    $self->{'their_features'} = $req->{'features'};
	}

	if (defined $self->{'their_features'} and
	    $self->{'their_features'}->has($Amanda::Feature::fe_amrecover_stream_state)) {
	    $self->send_rep(['CTL' => 'rw', 'DATA' => 'w', 'STATE' => 'rw'], $errors);
	} else {
	    $self->send_rep(['CTL' => 'rw', 'DATA' => 'w'], $errors);
	}
	return $self->quit() if (@$errors);

	$self->{'ctl_stream'} = 'CTL';
	$self->{'data_stream'} = 'DATA';
	$self->{'state_stream'} = 'STATE';
    }

    $self->read_command();
}

sub read_command {
    my $self = shift;
    my $ctl_stream = $self->{'ctl_stream'};
    my $command = $self->{'command'} = {};

    my @known_commands = qw(
	HOST DISK DATESTAMP LABEL DEVICE FSF HEADER
	FEATURES CONFIG );
    while (1) {
	$_ = $self->getline($ctl_stream);
	$_ =~ s/\r?\n$//g;

	last if /^END$/;
	last if /^[0-9]+$/;

	if (/^([A-Z]+)(=(.*))?$/) {
	    my ($cmd, $val) = ($1, $3);
	    if (!grep { $_ eq $cmd } @known_commands) {
		$self->sendmessage("invalid command '$cmd'");
		return $self->quit();
	    }
	    if (exists $command->{$cmd}) {
		warning("got duplicate command key '$cmd' from remote");
	    } else {
		$command->{$cmd} = $val || 1;
	    }
	}

	# features are handled specially.  This is pretty weird!
	if (/^FEATURES=/) {
	    my $featreply;
	    my $featurestr = $self->{'my_features'}->as_string();
	    if ($self->from_amandad) {
		$featreply = "FEATURES=$featurestr\r\n";
	    } else {
		$featreply = $featurestr;
	    }

	    $self->senddata($ctl_stream, $featreply);
	}
	$_ =~ s/\r?\n$//g;
    }

    # process some info from the command
    if ($command->{'FEATURES'}) {
	$self->{'their_features'} = Amanda::Feature::Set->from_string($command->{'FEATURES'});
    }

    if($self->{'their_features'}->has($Amanda::Feature::fe_amrecover_stream_state)) {
	debug("their_features have fe_amrecover_stream_state");
    } else {
	debug("their_features do not have fe_amrecover_stream_state");
    }

    # load the configuration
    if (!$command->{'CONFIG'}) {
	die "no CONFIG line given";
    }
    config_init_with_global($CONFIG_INIT_EXPLICIT_NAME, $command->{'CONFIG'});
    my ($cfgerr_level, @cfgerr_errors) = config_errors();
    if ($cfgerr_level >= $CFGERR_ERRORS) {
	die "configuration errors; aborting connection";
    }
    Amanda::Util::finish_setup($RUNNING_AS_DUMPUSER_PREFERRED);

    # and the disklist
    my $diskfile = Amanda::Config::config_dir_relative(getconf($CNF_DISKFILE));
    $cfgerr_level = Amanda::Disklist::read_disklist('filename' => $diskfile);
    if ($cfgerr_level >= $CFGERR_ERRORS) {
	die "Errors processing disklist";
    }

    $self->setup_data_stream();
}

sub setup_data_stream {
    my $self = shift;

    # if we're using amandad, then this is ready to roll - it's only inetd mode
    # that we need to fix
    if ($self->from_inetd()) {
	if ($self->{'their_features'}->has($Amanda::Feature::fe_recover_splits)) {
	    # remote side is expecting CONNECT
	    my $port = $self->connection_listen('DATA', 0);
	    $self->senddata($self->{'ctl_stream'}, "CONNECT $port\n");
	    $self->connection_accept('DATA', 30, sub { $self->got_connection(@_); });
	} else {
	    $self->{'ctl_stream'} = undef; # don't use this for ctl anymore
	    $self->{'data_stream'} = 'main';
	    $self->make_plan();
	}
    } else {
	$self->make_plan();
    }
}

sub got_connection {
    my $self = shift;
    my ($err) = @_;

    if ($err) {
	$self->sendmessage("$err");
	return $self->quit();
    }

    if (!$self->check_inetd_security('DATA')) {
	$main::exit_status = 1;
	return $self->quit();
    }
    $self->{'data_stream'} = 'DATA';

    $self->make_plan();
}

sub make_plan {
    my $self = shift;

    # put together a dumpspec
    my $spec;
    if (exists $self->{'command'}{'HOST'}
     || exists $self->{'command'}{'DISK'}
     || exists $self->{'command'}{'DATESTAMP'}) {
	my $disk = $self->{'command'}{'DISK'};
	if (!$self->{'their_features'}->has($Amanda::Feature::fe_amrecover_correct_disk_quoting)) {
	    debug("ignoring specified DISK, as it may be badly quoted");
	    $disk = undef;
	}
	$spec = Amanda::Cmdline::dumpspec_t->new(
	    $self->{'command'}{'HOST'},
	    $disk,
	    $self->{'command'}{'DATESTAMP'},
	    undef,  # amidxtaped protocol does not provide a level (!?)
	    undef); # amidxtaped protocol does not provide a write timestamp
    }

    # figure out if this is a holding-disk recovery
    my $is_holding = 0;
    if ((!exists $self->{'command'}{'LABEL'} and exists $self->{'command'}{'DEVICE'}) ||
	$self->{'command'}{'DEVICE'} =~ /HOLDING:\//) {
	$is_holding = 1;
    }

    my $chg;
    if ($is_holding) {
	# for holding, give the clerk a null; it won't touch it
	$chg = Amanda::Changer->new("chg-null:");
    } else {
	# if not doing a holding-disk recovery, then we will need a changer.
	# If we're using the "default" changer, instantiate that.  There are
	# several ways the user can specify the default changer:
	my $use_default = 0;
	if (!exists $self->{'command'}{'DEVICE'}) {
	    $use_default = 1;
	} elsif ($self->{'command'}{'DEVICE'} eq getconf($CNF_AMRECOVER_CHANGER)) {
	    $use_default = 1;
	}

	my $tlf = Amanda::Config::config_dir_relative(getconf($CNF_TAPELIST));
	my ($tl, $message) = Amanda::Tapelist->new($tlf);
	if (defined $message) {
	    die "Could not read the tapelist: $message";
	}
	if (!$use_default) {
	    $self->{'storage'} = Amanda::Storage->new(storage_name => $self->{'command'}{'DEVICE'},
						      tapelist => $tl);
	    if ($self->{'storage'}->isa("Amanda::Changer::Error")) {
		$self->{'storage'} = Amanda::Storage->new(tapelist => $tl);
		if ($self->{'storage'}->isa("Amanda::Changer::Error")) {
		    die("$self->{'storage'}");
		}
		$chg = Amanda::Changer->new($self->{'command'}{'DEVICE'},
					    storage => $self->{'storage'}, tapelist => $tl);
		$self->{'storage'}->{'chg'}->quit();
		$self->{'storage'}->{'chg'} = $chg;
	    } else {
		$chg = $self->{'storage'}->{'chg'};
	    }
	}
	if (!$self->{'storage'}) {
	    if ($self->{'their_features'}->has($Amanda::Feature::fe_amrecover_storage_in_marshall)) {
		my $filelist = Amanda::Util::unmarshal_tapespec(1,
						 $self->{'command'}{'LABEL'});
		my $storage_name = $filelist->[0];
		$self->{'storage'}  = Amanda::Storage->new(
				storage_name => $storage_name, tapelist => $tl);
	    }
	    if (!$self->{'storage'} ||
		$self->{'storage'}->isa("Amanda::Changer::Error")) {
	        warning("$self->{'storage'}") if $self->{'storage'};
		$self->{'storage'} =  Amanda::Storage->new(tapelist => $tl);
		if ($use_default) {
		    $chg = Amanda::Changer->new(undef,
					        storage => $self->{'storage'},
						tapelist => $tl);
		} else {
		    $chg = Amanda::Changer->new($self->{'command'}{'DEVICE'},
						storage => $self->{'storage'},
						tapelist => $tl);
		}
		if ($chg->isa("Amanda::Changer::Error")) {
	            $chg = Amanda::Changer->new("chg-null:");
		}
	    } else {
		$chg = $self->{'storage'}->{'chg'};
	    }
	}

	# if we got a bogus changer, log it to the debug log, but allow the
	# scan algorithm to find a good one later.
	if ($chg->isa("Amanda::Changer::Error")) {
	    warning("$chg");
	    $chg = Amanda::Changer->new("chg-null:");
	}
    }
    $self->{'chg'} = $chg;

    my $interactivity = Amanda::Interactivity::amidxtaped->new(clientservice => $self);
    $self->{'interactivity'} = $interactivity;

    my $scan = Amanda::Recovery::Scan->new(
			chg => $chg,
			interactivity => $self->{'interactivity'});
    $self->{'scan'} = $scan;

    # XXX temporary
    $scan->{'scan_conf'}->{'driveinuse'} = Amanda::Recovery::Scan::SCAN_ASK;
    $scan->{'scan_conf'}->{'volinuse'} = Amanda::Recovery::Scan::SCAN_ASK;
    $scan->{'scan_conf'}->{'notfound'} = Amanda::Recovery::Scan::SCAN_ASK;

    $self->{'clerk'} = Amanda::Recovery::Clerk->new(
	# note that we don't have any use for clerk_notif's, so we don't pass
	# a feedback object
	scan => $scan);

    if ($is_holding) {
	# if this is a holding recovery, then the plan is pretty easy.  The holding
	# file is given to us in the aptly-named DEVICE command key, with a :0 suffix
	my $holding_file_tapespec = $self->{'command'}{'DEVICE'};
	my $holding_file = $self->tapespec_to_holding($holding_file_tapespec);

	return Amanda::Recovery::Planner::make_plan(
	    holding_file => $holding_file,
	    $spec? (dumpspec => $spec) : (),
	    plan_cb => sub { $self->plan_cb(@_); });
    } else {
	my $filelist = Amanda::Util::unmarshal_tapespec(0+$self->{'their_features'}->has($Amanda::Feature::fe_amrecover_storage_in_marshall), $self->{'command'}{'LABEL'});
	# if LABEL was just a label, then FSF should contain the filenum we want to
	# start with.
	if ($filelist->[2][0] == 0) {
	    if (exists $self->{'command'}{'FSF'}) {
		$filelist->[2][0] = 0+$self->{'command'}{'FSF'};
		# note that if this is a split dump, make_plan will helpfully find the
		# remaining parts and include them in the restore.  Pretty spiffy.
	    } else {
		# we have only a label and (hopefully) a dumpspec, so let's see if the
		# catalog can find a dump for us.
		$filelist = $self->try_to_find_dump(
#			$self->{'command'}{'LABEL'},
			$filelist->[0],
			$filelist->[1],
			$spec);
		if (!$filelist) {
		    return $self->quit();
		}
	    }
	}

	return Amanda::Recovery::Planner::make_plan(
	    filelist => $filelist,
	    chg => $chg,
	    $spec? (dumpspec => $spec) : (),
	    plan_cb => sub { $self->plan_cb(@_); });
    }
}

sub plan_cb {
    my $self = shift;
    my ($err, $plan) = @_;

    if ($err) {
	$self->sendmessage("$err");
	return $self->quit();
    }

    if (@{$plan->{'dumps'}} > 1) {
	$self->sendmessage("multiple matching dumps; cannot recover");
	return $self->quit();
    }

    # check that the request-limit for this DLE allows this recovery.  because
    # of the bass-ackward way that amrecover specifies the dump to us, we can't
    # check the results until *after* the plan was created.
    my $dump = $plan->{'dumps'}->[0];
    $self->{'dump'} = $dump;
    my $dle = Amanda::Disklist::get_disk($dump->{'hostname'}, $dump->{'diskname'});
    my $recovery_limit;
    if ($dle && dumptype_seen($dle->{'config'}, $DUMPTYPE_RECOVERY_LIMIT)) {
	debug("using DLE recovery limit");
	$recovery_limit = dumptype_getconf($dle->{'config'}, $DUMPTYPE_RECOVERY_LIMIT);
    } elsif (getconf_seen($CNF_RECOVERY_LIMIT)) {
	debug("using global recovery limit as default");
	$recovery_limit = getconf($CNF_RECOVERY_LIMIT);
    }
    my $peer = $ENV{'AMANDA_AUTHENTICATED_PEER'};
    if (defined $recovery_limit) { # undef -> no recovery limit
	if (!$peer) {
	    warning("a recovery limit is specified for this DLE, but no authenticated ".
		    "peer name is available; rejecting request.");
	    $self->sendmessage("No matching dumps found");
	    return $self->quit();
	}
	my $matched = 0;
	for my $rl (@$recovery_limit) {
	    if ($rl eq $Amanda::Config::LIMIT_SAMEHOST) {
		# handle same-host with a case-insensitive string compare, not match_host
		if (lc($peer) eq lc($dump->{'hostname'})) {
		    $matched = 1;
		    last;
		}
	    } elsif ($rl eq $Amanda::Config::LIMIT_SERVER) {
		# handle server with a case-insensitive string compare, not match_host
		my $myhostname = hostname;
		debug("myhostname: $myhostname");
		if (lc($peer) eq lc($myhostname)) {
		    $matched = 1;
		    last;
		}
	    } else {
		# otherwise use match_host to allow match expressions
		if (match_host($rl, $peer)) {
		    $matched = 1;
		    last;
		}
	    }
	}
	if (!$matched) {
	    warning("authenticated peer '$peer' did not match recovery-limit ".
		    "config; rejecting request");
	    $self->sendmessage("No matching dumps found");
	    return $self->quit();
	}
    }

    if (!$self->{'their_features'}->has($Amanda::Feature::fe_recover_splits)) {
	# if we have greater than one volume, we may need to prompt for a new
	# volume in mid-recovery.  Sadly, we have no way to inform the client of
	# this.  In hopes that this will "just work", we just issue a warning.
	my @vols = $plan->get_volume_list();
	warning("client does not support split dumps; restore may fail if " .
		"interaction is necessary");
    }

    ($self->{'fetchdump'}, my $result_message) = Amanda::FetchDump->new();
    $self->{'fetchdump'}->restore(
		'plan'		=> $plan,
		#'pipe'		=> 1,
		'pipe-fd'	=> $self->wfd($self->{'data_stream'}),
		'header'	=> $self->{'command'}{'HEADER'} ? 1 : undef,
		'interactivity'	=> $self->{'interactivity'},
		'scan'		=> $self->{'scan'},
		'clerk'		=> $self->{'clerk'},
		'feedback'	=> $self,
		'their_features' => $self->{'their_features'},
		'finished_cb'	=> sub {
					$main::exit_status = shift;
					$self->quit();
				       });

    return;
}

sub send_state_file {
    my $self = shift;
    my $header = shift;

    if ($self->{'state_stream'} &&
	$self->{'their_features'}->has($Amanda::Feature::fe_amrecover_stream_state)) {
        my $host = Amanda::Util::sanitise_filename("" . $header->{'name'});
        my $disk = Amanda::Util::sanitise_filename("" . $header->{'disk'});
        my $state_filename = getconf($CNF_INDEXDIR) . '/' . $host .
                '/' . $disk . '/' . $header->{'datestamp'} . '_' .
                $header->{'dumplevel'} . '.state';
        if (-e $state_filename) {
            open STATEFILE, '<', $state_filename;
            my $block;
            my $length;
            while ($length = sysread(STATEFILE, $block, 32768)) {
                Amanda::Util::full_write($self->wfd($self->{'state_stream'}),
                                     $block, $length)
                    or die "writing to $self->{state_stream}: $!";
            }
        }
        $self->close($self->{'state_stream'}, 'w');

	# amandad can mix packet from multiple stream
	# but amrecover except this close before the next packet (header)
	# temporary fix until the protocol is enhanced or amrecover fixed.
	# delay sending the header packet
	sleep(1);
    }
}

sub expect_dar {
    my $self = shift;

    $self->{'use_dar'} = 0;
    $self->{'ignore_dar'} = 0;

    if ($self->from_inetd()) {
	return;
    }
    # short-circuit this if amrecover doesn't support dar
    if (!$self->{'their_features'}->has($Amanda::Feature::fe_amidxtaped_dar)) {
	return;
    }

    my $line = $self->getline($self->{'ctl_stream'});
    if ($line eq "ABORT\r\n") {
	return Amanda::MainLoop::quit();
    }
    my $darspec = ($line =~ /^USE-DAR (.*)\r\n$/);
    return ($1 eq 'YES');

    $self->{'use_dar'} = ($1 eq 'YES');
    $self->{'ignore_dar'} =  $self->{'use_dar'} &&
			    ($self->{'header'}->{'compressed'} ||
			     $self->{'header'}->{'encrypted'});
}

sub start_read_dar {
    my $self = shift;
    my $xfer_dest = shift;
    my $cb_data = shift;
    my $cb_done = shift;
    my $text = shift;

    $self->{'dar_cb'} = $cb_data;
    return;
}

sub expect_datapath {
    my $self = shift;

    $self->{'datapath'} = 'none';

    if ($self->from_inetd()) {
	return;
    }
    # short-circuit this if amrecover doesn't support datapaths
    if (!$self->{'their_features'}->has($Amanda::Feature::fe_amidxtaped_datapath)) {
	return;
    }

    my $line = $self->getline($self->{'ctl_stream'});
    if ($line eq "ABORT\r\n") {
	return Amanda::MainLoop::quit();
    }
    my ($dpspec) = ($line =~ /^AVAIL-DATAPATH (.*)\r\n$/);
    die "bad AVAIL-DATAPATH line" unless $dpspec;
    my @avail_dps = split / /, $dpspec;

    if (grep /^DIRECT-TCP$/, @avail_dps) {
	# remote can handle a directtcp transfer .. can we?
	if ($self->{'xfer_src_supports_directtcp'}) {
	    $self->{'datapath'} = 'directtcp';
	} else {
	    $self->{'datapath'} = 'amanda';
	}
    } else {
	# remote can at least handle AMANDA
	die "remote cannot handle AMANDA datapath??"
	    unless grep /^AMANDA$/, @avail_dps;
	$self->{'datapath'} = 'amanda';
    }
}

sub check_datapath {
    my $self = shift;


    if ($self->{'datapath'} eq 'amanda') {
	$self->sendctlline("USE-DATAPATH AMANDA\r\n");
	my $dpline = $self->getline($self->{'ctl_stream'});
	if ($dpline ne "DATAPATH-OK\r\n") {
	    return "expected DATAPATH-OK";
	}
    }
    return;
}

sub send_directtcp_datapath {
    my $self = shift;

    # send the data-path response, if we have a datapath
    if ($self->{'datapath'} eq 'directtcp') {
	my $addrs = $self->{'fetchdump'}->{'xfer_dest'}->get_addrs();
	$addrs = [ map { $_->[0] . ":" . $_->[1] } @$addrs ];
	$addrs = join(" ", @$addrs);
	$self->sendctlline("USE-DATAPATH DIRECT-TCP $addrs\r\n");
	my $dpline = $self->getline($self->{'ctl_stream'});
	if ($dpline ne "DATAPATH-OK\r\n") {
	    return "expected DATAPATH-OK";
	}
    }
}

sub start_msg {
    my $self = shift;
    my $dar_data_cb = shift;

    return if !defined $self->{'ctl_stream'};
    $self->{'ctl_src'} = Amanda::MainLoop::fd_source(
				$self->rfd($self->{'ctl_stream'}),
				$G_IO_IN|$G_IO_HUP|$G_IO_ERR);
    my $ctl_buffer;
    $self->{'ctl_src'}->set_callback( sub {
	my $b;
	my $n_read = POSIX::read($self->rfd($self->{'ctl_stream'}), $b, 1);
	if (!defined $n_read) {
	    debug("Failure to read ctl_stream: $!");
	    $self->{'ctl_src'}->remove();
	    $self->{'ctl_src'} = undef;
	    $ctl_buffer = undef;
	    return;
	} elsif ($n_read == 0) {
	    $dar_data_cb->("DAR 0:-1");
	} else {
	    $ctl_buffer .= $b;
	    if ($b eq "\n") {
		my $line = $ctl_buffer;
		chomp $line;
		chop $line; # remove '\r'
		debug("ctl line: $line");
		if ($line =~ /^OK$/) {
		} elsif ($line =~ /^TAPE (.*)$/) {
		} elsif ($line =~ /^DAR .*$/) {
		    $dar_data_cb->($line);
		} elsif ($line =~ /^DAR-DONE$/) {
		    $dar_data_cb->("DAR -1:0");
		}
		$ctl_buffer = "";
	    }
	}
    });
}


sub quit {
    my $self = shift;

    if ($self->{'clerk'}) {
	$self->{'clerk'}->quit(finished_cb => sub {
	    my ($err) = @_;
	    $self->{'chg'}->quit() if defined $self->{'chg'};
	    if ($err) {
		# it's *way* too late to report this to amrecover now!
		warning("while quitting clerk: $err");
	    }
	    $self->quit1();
	});
    } else {
	$self->{'scan'}->quit() if defined $self->{'scan'};
	$self->{'chg'}->quit() if defined $self->{'chg'};
	$self->quit1();
    }

}

sub quit1 {
    my $self = shift;

    $self->{'storage'}->quit() if defined($self->{'storage'});
    $self->{'fetch_done'} = 1;
    if (!%{$self->{'all_filter'}}) {
	Amanda::MainLoop::quit();
    }
}

## utilities

sub check_inetd_security {
    my $self = shift;
    my ($stream) = @_;

    my $firstline = $self->getline($stream);
    if ($firstline !~ /^SECURITY (.*)\n/) {
	warning("did not get security line");
	print "ERROR did not get security line\r\n";
	return 0;
    }

    my $errmsg = $self->check_bsd_security($stream, $1, "amidxtaped");
    if ($errmsg) {
	print "ERROR $errmsg\r\n";
	return 0;
    }

    return 1;
}

sub get_req {
    my $self = shift;

    my $req_str = '';
    while (1) {
	my $buf = Amanda::Util::full_read($self->rfd('main'), 1024);
	last unless $buf;
	$req_str .= $buf;
    }
    # we've read main to EOF, so close it
    $self->close('main', 'r');

    return $self->{'req'} = $self->parse_req($req_str);
}

sub send_rep {
    my $self = shift;
    my ($streams, $errors) = @_;
    my $rep = '';

    # first, if there were errors in the REQ, report them
    if (@$errors) {
	for my $err (@$errors) {
	    $rep .= "ERROR $err\n";
	}
    } else {
	my $connline = $self->connect_streams(@$streams);
	$rep .= "$connline\n";
    }
    # rep needs a empty-line terminator, I think
    $rep .= "\n";

    # write the whole rep packet, and close main to signal the end of the packet
    $self->senddata('main', $rep);
    $self->close('main', 'w');
}

# helper function to get a line, including the trailing '\n', from a stream.  This
# reads a character at a time to ensure that no extra characters are consumed.  This
# could certainly be more efficient! (TODO)
sub getline {
    my $self = shift;
    my ($stream) = @_;
    my $fd = $self->rfd($stream);
    my $line = '';

    while (1) {
	my $c;
	POSIX::read($fd, $c, 1)
	    or last;
	$line .= $c;
	last if $c eq "\n";
    }

    $line =~ /^(.*)$/;
    my $chopped = $1;
    $chopped =~ s/[\r\n]*$//g;
    debug("CTL << $chopped");

    return $line;
}

# like getline, but async; TODO:
#  - make all uses of getline async
#  - use buffering to read more than one character at a time
sub getline_async {
    my $self = shift;
    my ($stream, $async_read_cb) = @_;
    my $fd = $self->rfd($stream);

    my $data_in;
    my $buf = '';

    $data_in = sub {
	my ($err, $data) = @_;

	return $async_read_cb->($err, undef) if $err;

	$buf .= $data;
	if ($buf =~ /^(.*\r\n)$/) {
	    my $chopped = $1;
	    $chopped =~ s/[\r\n]*$//g;
	    debug("CTL << $chopped");

	    $async_read_cb->(undef, $buf);
	} else {
	    Amanda::MainLoop::async_read(fd => $fd, size => 1, async_read_cb => $data_in);
	}
    };
    Amanda::MainLoop::async_read(fd => $fd, size => 1, async_read_cb => $data_in);
}

# helper function to write a data to a stream.  This does not add newline characters.
# If the callback is given, this is async (TODO: all calls should be async)
sub senddata {
    my $self = shift;
    my ($stream, $data, $async_write_cb) = @_;
    my $fd = $self->wfd($stream);

    if (defined $async_write_cb) {
	return Amanda::MainLoop::async_write(
		fd => $fd,
		data => $data,
		async_write_cb => $async_write_cb);
    } else {
	Amanda::Util::full_write($fd, $data, length($data))
	    or die "writing to $stream: $!";
    }
}

# send a line on the control stream, or just log it if the ctl stream is gone;
# async callback is just like for senddata
sub sendctlline {
    my $self = shift;
    my ($msg, $async_write_cb) = @_;

    my $chopped = $msg;
    $chopped =~ s/[\r\n]*$//g;

    if ($self->{'ctl_stream'}) {
	debug("CTL >> $chopped");
	return $self->senddata($self->{'ctl_stream'}, $msg, $async_write_cb);
    } else {
	debug("not sending CTL message as CTL is closed >> $chopped");
	if (defined $async_write_cb) {
	    $async_write_cb->(undef, length($msg));
	}
    }
}

# send a MESSAGE on the CTL stream, but only if the remote has
# fe_amrecover_message
sub sendmessage {
    my $self = shift;
    my ($msg) = @_;

    if ($self->{'their_features'}->has($Amanda::Feature::fe_amrecover_message)) {
	$self->sendctlline("MESSAGE $msg\r\n");
    } else {
	warning("remote does not understand MESSAGE; not sent: MESSAGE $msg");
    }
}

# covert a tapespec to a holding filename
sub tapespec_to_holding {
    my $self = shift;
    my ($tapespec) = @_;

    my $filelist = Amanda::Util::unmarshal_tapespec(0, $tapespec);

    # $filelist should have the form [ "HOLDING", $holding_file, [ 0 ] ]
    die "invalid holding tapespec" unless @$filelist == 3;
    die "invalid holding tapespec" unless $filelist->[0] eq "HOLDING";
    die "invalid holding tapespec" unless @{$filelist->[2]} == 1;
    die "invalid holding tapespec" unless $filelist->[2][0] == 0;

    return $filelist->[1];
}

# amrecover didn't give us much to go on, but see if we can find a dump that
# will make it happy.
sub try_to_find_dump {
    my $self = shift;
    my ($storage, $label, $spec) = @_;

    # search the catalog; get_dumps cannot search by labels, so we have to use
    # get_parts instead
    my @parts = Amanda::DB::Catalog::get_parts(
	storage => $storage,
	label => $label,
	dumpspecs => [ $spec ]);

    if (!@parts) {
	$self->sendmessage("could not find any matching dumps on volume '$label'");
	return undef;
    }

    # (note that if there is more than one dump in @parts, the planner will
    # catch it later)

    # sort the parts by their order on each volume.  This sorts the volumes
    # lexically by label, but the planner will straighten it out.
    @parts = Amanda::DB::Catalog::sort_dumps([ "label", "filenum" ], @parts);

    # loop over the parts for the dump and make a filelist.
    my $last_label = '';
    my $last_filenums = undef;
    my $filelist = [];
    for my $part (@parts) {
	next unless defined $part; # skip part number 0
	if ($part->{'label'} ne $last_label) {
	    $last_label = $part->{'label'};
	    $last_filenums = [];
	    push @$filelist, $part->{'storage'}, $last_label, $last_filenums;
	}
	push @$last_filenums, $part->{'filenum'};
    }

    return $filelist;
}

##
# main driver

package main;

use Amanda::Debug qw( debug );
use Amanda::Util qw( :constants );
use Amanda::Config qw( :init );

our $exit_status = 0;

Amanda::Util::setup_application("amidxtaped", "server", $CONTEXT_DAEMON, "amanda", "amanda");
config_init($CONFIG_INIT_GLOBAL, undef);

my $amidxtaped = amidxtaped->new();
Amanda::MainLoop::call_later(sub { $amidxtaped->run(); });
Amanda::MainLoop::run();

debug("exiting with $exit_status");
Amanda::Util::finish_application();

exit($exit_status);
