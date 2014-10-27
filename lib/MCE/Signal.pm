###############################################################################
## ----------------------------------------------------------------------------
## MCE::Signal - Temporary directory creation/cleanup & signal handling.
##
###############################################################################

package MCE::Signal;

use strict;
use warnings;

use Fcntl qw( :flock O_RDONLY );
use base qw( Exporter );

our $VERSION = '1.519'; $VERSION = eval $VERSION;

our ($has_threads, $main_proc_id, $prog_name);
our ($display_die_with_localtime, $display_warn_with_localtime);

BEGIN {
   require File::Path;

   $main_proc_id =  $$;
   $prog_name    =  $0;
   $prog_name    =~ s{^.*[\\/]}{}g;
}

our $tmp_dir = undef;

our @EXPORT_OK = qw( $tmp_dir sys_cmd stop_and_exit );
our %EXPORT_TAGS = (
   all     => \@EXPORT_OK,
   tmp_dir => [ qw( $tmp_dir ) ]
);

###############################################################################
## ----------------------------------------------------------------------------
## Process import, export, & module arguments.
##
###############################################################################

sub _croak { require Carp; goto &Carp::croak; }
sub _usage { _croak "MCE::Signal error: $_[0] is not a valid option"; }
sub _flag  { 1; }

my $_is_MSWin32   = ($^O eq 'MSWin32');
my $_keep_tmp_dir = 0;
my $_no_sigmsg    = 0;
my $_no_kill9     = 0;
my $_loaded;

sub import {

   my $class = shift;
   return if ($_loaded++);

   my @_export_args = ();
   my $_no_setpgrp  = 0;
   my $_setpgrp     = 0;
   my $_use_dev_shm = 0;

   while (my $_arg = shift) {

      $_keep_tmp_dir = _flag() and next if ($_arg eq '-keep_tmp_dir');
      $_no_sigmsg    = _flag() and next if ($_arg eq '-no_sigmsg');
      $_no_kill9     = _flag() and next if ($_arg eq '-no_kill9');

      $_no_setpgrp   = _flag() and next if ($_arg eq '-no_setpgrp');
      $_setpgrp      = _flag() and next if ($_arg eq '-setpgrp');

      $_use_dev_shm  = _flag() and next if ($_arg eq '-use_dev_shm');

      _usage($_arg) if ($_arg =~ /^-/);
      push @_export_args, $_arg;
   }

   local $Exporter::ExportLevel = 1;
   Exporter::import($class, @_export_args);

 # ## MCE no longer calls setpgrp by default as of MCE 1.405.
 # ## Sets the current process group for the current process.
 # setpgrp(0,0) if ($_no_setpgrp == 0 && $^O ne 'MSWin32');

   ## Sets the current process group for the current process.
   setpgrp(0,0) if ($_setpgrp == 1 && $^O ne 'MSWin32');

   my ($_tmp_dir_base, $_count);

   if (exists $ENV{TEMP}) {
      if ($_is_MSWin32) {
         $_tmp_dir_base = $ENV{TEMP} . '/mce';
         mkdir $_tmp_dir_base unless (-d $_tmp_dir_base);
      }
      else {
         $_tmp_dir_base = $ENV{TEMP};
      }
   }
   else {
      $_tmp_dir_base = ($_use_dev_shm && -d '/dev/shm' && -w '/dev/shm')
         ? '/dev/shm' : '/tmp';
   }

   _croak("MCE::Signal::import: '$_tmp_dir_base' is not writeable")
      unless (-w $_tmp_dir_base);

   $_count  = 0;
   $tmp_dir = "$_tmp_dir_base/$prog_name.$$.$_count";

   while ( !(mkdir "$tmp_dir", 0770) ) {
      $tmp_dir = "$_tmp_dir_base/$prog_name.$$." . (++$_count);
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Configure signal handling.
##
###############################################################################

our ($mce_sess_dir_ref, $mce_spawned_ref);

## Set traps to catch signals.
$SIG{XCPU} = \&stop_and_exit if (exists $SIG{XCPU});   ## UNIX SIG 24
$SIG{XFSZ} = \&stop_and_exit if (exists $SIG{XFSZ});   ## UNIX SIG 25

$SIG{HUP}  = \&stop_and_exit;                          ## UNIX SIG  1
$SIG{INT}  = \&stop_and_exit;                          ## UNIX SIG  2
$SIG{PIPE} = \&stop_and_exit;                          ## UNIX SIG 13
$SIG{QUIT} = \&stop_and_exit;                          ## UNIX SIG  3
$SIG{TERM} = \&stop_and_exit;                          ## UNIX SIG 15

## For a more reliable MCE, $SIG{CHLD} is set to 'DEFAULT'. MCE handles
## the reaping of its children, especially when running multiple MCEs
## simultaneously.
##
$SIG{CHLD} = 'DEFAULT' unless ($_is_MSWin32);

###############################################################################
## ----------------------------------------------------------------------------
## Call stop_and_exit when exiting the script.
##
###############################################################################

END {
   my $_exit_status = $?;

   MCE::Signal->_shutdown_mce($_exit_status)
      if (defined $mce_spawned_ref);

   MCE::Signal->stop_and_exit($_exit_status)
      if ($$ == $main_proc_id);
}

###############################################################################
## ----------------------------------------------------------------------------
## Run command via the system(...) function.
##
## The system function in Perl ignores SIGINT and SIGQUIT. These 2 signals
## are sent to the command being executed via system() but not back to
## the underlying Perl script. The code below will ensure the Perl script
## receives the same signal in order to raise an exception immediately
## after the system call.
##
## Returns the actual exit status.
##
###############################################################################

sub sys_cmd {

   shift @_ if (defined $_[0] && $_[0] eq 'MCE::Signal');
   _croak("MCE::Signal::sys_cmd: no arguments were specified") if (@_ == 0);

   my $_status = system(@_);
   my $_sig_no = $_status & 127;
   my $_exit_status = $_status >> 8;

   ## Kill the process group if command caught SIGINT or SIGQUIT.

   kill('INT',  $main_proc_id, ($_is_MSWin32 ? -$$ : -getpgrp()))
      if $_sig_no == 2;

   kill('QUIT', $main_proc_id, ($_is_MSWin32 ? -$$ : -getpgrp()))
      if $_sig_no == 3;

   return $_exit_status;
}

###############################################################################
## ----------------------------------------------------------------------------
## Stops execution, removes temp directory and exits cleanly.
##
## Provides safe reentrant logic for both parent and child processes.
## The $main_proc_id variable is defined above.
##
###############################################################################

{
   my $_handler_cnt = 0;

   my %_sig_name_lkup = map { $_ => 1 } qw(
      __DIE__ __WARN__ HUP INT PIPE QUIT TERM CHLD XCPU XFSZ
   );

   sub stop_and_exit {

      shift @_ if (defined $_[0] && $_[0] eq 'MCE::Signal');

      my $_sig_name    = $_[0] || 0;
      my $_exit_status = $?;
      my $_is_sig      = 0;

      if (exists $_sig_name_lkup{$_sig_name}) {
         $mce_spawned_ref = undef;
         $SIG{$_sig_name} = sub { };
         $_exit_status = $_is_sig = 1;
      }
      else {
         $_exit_status = $_sig_name if ($_sig_name ne '0');
      }

      $SIG{TERM} = sub { } if ($_sig_name ne 'TERM');
      $SIG{__DIE__} = $SIG{__WARN__} = sub { };

      ## ----------------------------------------------------------------------

      ## For the main thread / manager process.
      if ($$ == $main_proc_id) {

         if (++$_handler_cnt == 1 && ! -e "$tmp_dir/stopped") {
            open my $_FH, "> $tmp_dir/stopped"; close $_FH;

            local $\ = undef;

            ## Display message and kill process group if signaled.
            if ($_is_sig == 1) {
               my $_err_msg = undef;

               if ($_sig_name eq 'XCPU') {
                  $_err_msg = "exceeded CPU time limit, exiting";
               }
               elsif ($_sig_name eq 'XFSZ') {
                  $_err_msg = "exceeded file size limit, exiting";
               }
               elsif ($_sig_name eq 'TERM' && -f "$tmp_dir/died") {
                  $_err_msg = "caught signal '__DIE__', exiting";
               }
               elsif ($_sig_name eq '__DIE__') {
                  $_err_msg = "caught signal '__DIE__', exiting";
               }
               elsif ($_sig_name ne 'PIPE') {
                  $_err_msg = "caught signal '$_sig_name', exiting";
               }

               ## Display error message.
               print STDERR "\n## $prog_name: $_err_msg\n"
                  if ($_err_msg && $_no_sigmsg == 0);

               open my $_FH, "> $tmp_dir/killed"; close $_FH;

               ## Signal process group to terminate.
               kill('TERM', $_is_MSWin32 ? -$$ : -getpgrp());

               ## Pause a bit.
               if ($_sig_name ne 'PIPE') {
                  select(undef, undef, undef, 0.066) for (1..3);
               } else {
                  select(undef, undef, undef, 0.011) for (1..2);
               }
            }

            ## Remove temp directory.
            if (defined $tmp_dir && $tmp_dir ne '' && -d $tmp_dir) {

               if (defined $mce_sess_dir_ref) {
                  foreach my $_sess_dir (keys %{ $mce_sess_dir_ref }) {
                     File::Path::rmtree($_sess_dir);
                     delete $mce_sess_dir_ref->{$_sess_dir};
                  }
               }

               if ($_keep_tmp_dir == 1) {
                  print STDERR "$prog_name: saved tmp_dir = $tmp_dir\n";
               }
               else {
                  if ($tmp_dir ne '/tmp' && $tmp_dir ne '/var/tmp') {
                     File::Path::rmtree($tmp_dir);
                  }
               }

               $tmp_dir = undef;
            }

            ## Signal process group to die.
            if ($_is_sig == 1) {
               print STDERR "\n" if ($_sig_name ne 'PIPE' && $_no_sigmsg == 0);

               if ($_no_kill9 == 1 || $_sig_name eq 'PIPE') {
                  kill('TERM', $_is_MSWin32 ? -$$ : -getpgrp(), $main_proc_id);
               }
               else {
                  kill('KILL', $_is_MSWin32 ? -$$ : -getpgrp(), $main_proc_id);
               }
            }
         }
      }

      ## ----------------------------------------------------------------------

      ## For child processes.
      if ($$ != $main_proc_id && $_is_sig == 1 && -d $tmp_dir) {

         ## Signal process group to terminate.
         if (++$_handler_cnt == 1) {

            ## Obtain lock.
            open my $CHILD_LOCK, '+>>', "$tmp_dir/child.lock";
            flock $CHILD_LOCK, LOCK_EX;

            ## Notify the main process that I've died.
            if ($_sig_name eq '__DIE__' && ! -f "$tmp_dir/died") {
               local $@; eval '
                  open my $_FH, "> $tmp_dir/died"; close $_FH;
               ';
            }

            ## Signal process group to terminate.
            if (! -f "$tmp_dir/killed" && ! -f "$tmp_dir/stopped") {
               local $@; eval '
                  open my $_FH, "> $tmp_dir/killed"; close $_FH;
               ';
               kill('TERM', $main_proc_id, -$$);
            }

            ## Release lock.
            flock $CHILD_LOCK, LOCK_UN;
            close $CHILD_LOCK;
         }
      }

      ## ----------------------------------------------------------------------

      ## Exit thread/process with status.
      if ($_is_sig == 1 && $_no_kill9 == 0) {
         select(undef, undef, undef, 0.066) for (1..6);
      }

      threads->exit($_exit_status)
         if ($has_threads && threads->can('exit'));

      CORE::exit($_exit_status);
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Shutdown MCEs that were previously initiated by this process ID and are
## still running.
##
###############################################################################

sub _shutdown_mce {

   shift @_ if (defined $_[0] && $_[0] eq 'MCE::Signal');
   my $_exit_status = $_[0] || $?;

   if (defined $mce_spawned_ref) {
      my $_tid = ($has_threads) ? threads->tid() : '';
      $_tid = '' unless defined $_tid;

      foreach my $_mce_sid (keys %{ $mce_spawned_ref }) {
         if ($mce_spawned_ref->{$_mce_sid}->wid()) {
            $mce_spawned_ref->{$_mce_sid}->exit($_exit_status);
         }
         else {
            $mce_spawned_ref->{$_mce_sid}->shutdown()
               if ($_mce_sid =~ /\A$$\.$_tid\./);
         }
         delete $mce_spawned_ref->{$_mce_sid};
      }
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Signal handlers for __DIE__ & __WARN__ utilized by MCE.
##
###############################################################################

sub _die_handler {

   shift @_ if (defined $_[0] && $_[0] eq 'MCE::Signal');

   CORE::die(@_) if $^S;      ## Direct to CORE::die if executing an eval

   local $\ = undef;

   ## Set $MCE::Signal::display_die_with_localtime = 1;
   ## when wanting the output to contain the localtime.

   if ($MCE::Signal::display_die_with_localtime) {
      my $_time_stamp = localtime();
      print STDERR "## $_time_stamp: $prog_name: ERROR:\n", $_[0];
   }
   else {
      print STDERR $_[0];
   }

   MCE::Signal->stop_and_exit('__DIE__');

   CORE::exit;
}

sub _warn_handler {

   shift @_ if (defined $_[0] && $_[0] eq 'MCE::Signal');

   ## Ignore thread warnings during exiting.

   return if (
      $_[0] =~ /^A thread exited while \d+ threads were running/ ||
      $_[0] =~ /^Attempt to free unreferenced scalar/            ||
      $_[0] =~ /^Perl exited with active threads/
   );

   local $\ = undef;

   ## Set $MCE::Signal::display_warn_with_localtime = 1;
   ## when wanting the output to contain the localtime.

   if ($MCE::Signal::display_warn_with_localtime) {
      my $_time_stamp = localtime();
      print STDERR "## $_time_stamp: $prog_name: WARNING:\n", $_[0];
   }
   else {
      print STDERR $_[0];
   }
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Signal - Temporary directory creation/cleanup & signal handling

=head1 VERSION

This document describes MCE::Signal version 1.519

=head1 SYNOPSIS

 use MCE::Signal qw( [-keep_tmp_dir] [-use_dev_shm] );

 use MCE;   ## MCE loads MCE::Signal when not present.
            ## Include MCE::Signal first for options to take effect.

=head1 DESCRIPTION

This package configures $SIG{HUP,INT,PIPE,QUIT,TERM,XCPU,XFSZ} to point to
stop_and_exit and creates a temporary directory. The main process and workers
receiving said signals call stop_and_exit, which signals all workers to
terminate, removes the temporary directory unless -keep_tmp_dir is specified,
and terminates itself.

The location of temp dir resides under $ENV{TEMP} if defined, otherwise
/dev/shm if writeable and -use_dev_shm is specified, or /tmp.

The temp dir resides under $ENV{TEMP}/mce/ for native Perl on Microsoft
Windows.

As of MCE 1.405, MCE::Signal no longer calls setpgrp by default. Pass the
-setpgrp option to MCE::Signal to call setpgrp.

 ## Running MCE through Daemon::Control requires setpgrp to be called
 ## for MCE releases 1.511 and below.

 use MCE::Signal qw(-setpgrp);   ## Not necessary for MCE 1.512 and above
 use MCE;

The following are available arguments and their meanings.

 -keep_tmp_dir     - The temporary directory is not removed during exiting
                     A message is displayed with the location afterwards

 -use_dev_shm      - Create the temporary directory under /dev/shm

 -no_sigmsg        - Do not display a message when receiving a signal
 -no_kill9         - Do not kill -9 after receiving a signal to terminate

 -setpgrp          - Calls setpgrp to set the process group for the process

                     This option ensures all workers terminate when reading
                     STDIN for MCE releases 1.511 and below.

                        cat big_input_file | ./mce_script.pl | head -10

                     This works fine without the -setpgrp option:

                        ./mce_script.pl < big_input_file | head -10

Nothing is exported by default. Exportable are 1 variable and 2 subroutines.

 $tmp_dir          - Path to the temporary directory.
 stop_and_exit     - Described below
 sys_cmd           - Described below

=head2 stop_and_exit ( [ $exit_status | $signal ] )

 ## Stops execution, removes temp directory and exits the entire
 ## application. Pass 'TERM' if wanting to terminate a spawned or
 ## running MCE state.

 MCE::Signal::stop_and_exit(1);
 MCE::Signal::stop_and_exit('TERM');

=head2 sys_cmd ( $command )

The system function in Perl ignores SIGNINT and SIGQUIT. These 2 signals are
sent to the command being executed via system() but not back to the underlying
Perl script. For this reason, sys_cmd was added to MCE::Signal.

 ## Execute command and return the actual exit status. The perl script
 ## is also signaled if command caught SIGINT or SIGQUIT.

 use MCE::Signal qw(sys_cmd);   ## Include before MCE
 use MCE;

 my $exit_status = sys_cmd($command);

=head1 EXAMPLES

 ## Creates tmp_dir under /tmp
 use MCE::Signal;
 use MCE::Signal qw( :all );

 ## Attempt to create tmp_dir under /dev/shm, otherwise under /tmp
 use MCE::Signal qw( -use_dev_shm );

 ## Keep tmp_dir after script terminates
 use MCE::Signal qw( -keep_tmp_dir );
 use MCE::Signal qw( -use_dev_shm -keep_tmp_dir );

=head1 INDEX

L<MCE>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.

=cut

