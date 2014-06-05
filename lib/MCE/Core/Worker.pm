###############################################################################
## ----------------------------------------------------------------------------
## MCE::Core::Worker - Core methods for the worker process.
##
## This package provides main, loop, and relevant methods used internally by
## the worker process.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Worker;

our $VERSION = '1.514'; $VERSION = eval $VERSION;

## Items below are folded into MCE.

package MCE;

use strict;
use warnings;

use bytes;

## Warnings are disabled to minimize bits of noise when user or OS signals
## the script to exit. e.g. MCE_script.pl < infile | head

no warnings 'threads'; no warnings 'uninitialized';

my $_die_msg;

END {
   MCE->exit(255, $_die_msg) if (defined $_die_msg);
}

###############################################################################
## ----------------------------------------------------------------------------
## Internal do, gather and send related functions for serializing data to
## destination. User functions for handling gather, queue or void.
##
###############################################################################

{
   my ($_DAT_LOCK, $_DAT_W_SOCK, $_DAU_W_SOCK, $_tag, $_value, $_want_id);
   my ($_chn, $_data_ref, $_dest, $_len, $_lock_chn, $_task_id, $_user_func);

   ## Create array structure containing various send functions.
   my @_dest_function = ();

   $_dest_function[SENDTO_FILEV2] = sub {         ## Content >> File

      return unless (defined $_value);

      my $_buffer = $_value . $LF . length(${ $_[0] }) . $LF . ${ $_[0] };

      local $\ = undef if (defined $\);

      flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
      print $_DAT_W_SOCK OUTPUT_F_SND . $LF . $_chn . $LF;
      print $_DAU_W_SOCK $_buffer;
      flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

      return;
   };

   $_dest_function[SENDTO_FD] = sub {             ## Content >> File descriptor

      return unless (defined $_value);

      my $_buffer = $_value . $LF . length(${ $_[0] }) . $LF . ${ $_[0] };

      local $\ = undef if (defined $\);

      flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
      print $_DAT_W_SOCK OUTPUT_D_SND . $LF . $_chn . $LF;
      print $_DAU_W_SOCK $_buffer;
      flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

      return;
   };

   $_dest_function[SENDTO_STDOUT] = sub {         ## Content >> STDOUT

      my $_buffer = length(${ $_[0] }) . $LF . ${ $_[0] };

      local $\ = undef if (defined $\);

      flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
      print $_DAT_W_SOCK OUTPUT_O_SND . $LF . $_chn . $LF;
      print $_DAU_W_SOCK $_buffer;
      flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

      return;
   };

   $_dest_function[SENDTO_STDERR] = sub {         ## Content >> STDERR

      my $_buffer = length(${ $_[0] }) . $LF . ${ $_[0] };

      local $\ = undef if (defined $\);

      flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
      print $_DAT_W_SOCK OUTPUT_E_SND . $LF . $_chn . $LF;
      print $_DAU_W_SOCK $_buffer;
      flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

      return;
   };

   ## -------------------------------------------------------------------------

   sub _do_callback {

      my $_buffer; my MCE $self = $_[0]; $_value = $_[1]; $_data_ref = $_[2];

      @_ = ();

      unless (defined wantarray) {
         $_want_id = WANTS_UNDEF;
      } elsif (wantarray) {
         $_want_id = WANTS_ARRAY;
      } else {
         $_want_id = WANTS_SCALAR;
      }

      ## Crossover: Send arguments

      if (@$_data_ref > 0) {                      ## Multiple Args >> Callback

         if (@$_data_ref > 1 || ref $_data_ref->[0]) {
            $_tag = OUTPUT_A_CBK;
            $_buffer = $self->{freeze}($_data_ref);
            $_buffer = $_want_id . $LF . $_value . $LF .
               length($_buffer) . $LF . $_buffer;
         }
         else {                                   ## Scalar >> Callback
            $_tag = OUTPUT_S_CBK;
            $_buffer = $_want_id . $LF . $_value . $LF .
               length($_data_ref->[0]) . $LF . $_data_ref->[0];
         }

         $_data_ref = '';
      }
      else {                                      ## No Args >> Callback
         $_tag = OUTPUT_N_CBK;
         $_buffer = $_want_id . $LF . $_value . $LF;
      }

      local $\ = undef if (defined $\);

      flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
      print $_DAT_W_SOCK $_tag . $LF . $_chn . $LF;
      print $_DAU_W_SOCK $_buffer;

      ## Crossover: Receive return value

      if ($_want_id == WANTS_UNDEF) {
         flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
         return;
      }
      elsif ($_want_id == WANTS_ARRAY) {
         local $/ = $LF if (!$/ || $/ ne $LF);

         chomp($_len = <$_DAU_W_SOCK>);
         read $_DAU_W_SOCK, $_buffer, $_len || 0;
         flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

         return @{ $self->{thaw}($_buffer) };
      }
      else {
         local $/ = $LF if (!$/ || $/ ne $LF);

         chomp($_want_id = <$_DAU_W_SOCK>);
         chomp($_len     = <$_DAU_W_SOCK>);

         if ($_len >= 0) {
            read $_DAU_W_SOCK, $_buffer, $_len || 0;
            flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

            return $_buffer if ($_want_id == WANTS_SCALAR);
            return $self->{thaw}($_buffer);
         }
         else {
            flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
            return;
         }
      }
   }

   ## -------------------------------------------------------------------------

   sub _do_gather {

      my MCE $self  = $_[0];
      my $_data_ref = $_[1];
      my $_buffer;

      return unless (scalar @{ $_data_ref });

      if (@{ $_data_ref } > 1) {
         $_tag = OUTPUT_A_GTR;
         $_buffer = $self->{freeze}($_data_ref);
         $_buffer = $_task_id . $LF . length($_buffer) . $LF . $_buffer;
      }
      elsif (ref $_data_ref->[0]) {
         $_tag = OUTPUT_R_GTR;
         $_buffer = $self->{freeze}($_data_ref->[0]);
         $_buffer = $_task_id . $LF . length($_buffer) . $LF . $_buffer;
      }
      elsif (scalar @{ $_data_ref }) {
         $_tag = OUTPUT_S_GTR;
         if (defined $_data_ref->[0]) {
            $_buffer = $_task_id . $LF . length($_data_ref->[0]) . $LF .
               $_data_ref->[0];
         }
         else {
            $_buffer = $_task_id . $LF . -1 . $LF;
         }
      }

      local $\ = undef if (defined $\);

      flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
      print $_DAT_W_SOCK $_tag . $LF . $_chn . $LF;
      print $_DAU_W_SOCK $_buffer;
      flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

      return;
   }

   ## -------------------------------------------------------------------------

   sub _do_send {

      my MCE $self = shift; $_dest = shift; $_value = shift;
      my $_buffer;

      if (@_ > 1) {
         $_buffer = join('', @_);
         return $_dest_function[$_dest](\$_buffer);
      }
      elsif (my $_ref = ref $_[0]) {
         if ($_ref eq 'SCALAR') {
            return $_dest_function[$_dest]($_[0]);
         } elsif ($_ref eq 'ARRAY') {
            $_buffer = join('', @{ $_[0] });
         } elsif ($_ref eq 'HASH') {
            $_buffer = join('', %{ $_[0] });
         } else {
            $_buffer = join('', @_);
         }
         return $_dest_function[$_dest](\$_buffer);
      }
      else {
         return $_dest_function[$_dest](\$_[0]);
      }
   }

   sub _do_send_glob {

      my MCE $self  = $_[0]; my $_glob = $_[1]; my $_fd = $_[2];
      my $_data_ref = $_[3];

      if ($self->{_wid} > 0) {
         if ($_fd == 1) {
            $self->_do_send(SENDTO_STDOUT, undef, $_data_ref);
         } elsif ($_fd == 2) {
            $self->_do_send(SENDTO_STDERR, undef, $_data_ref);
         } else {
            $self->_do_send(SENDTO_FD, $_fd, $_data_ref);
         }
      }
      else {
         my $_fh = qualify_to_ref($_glob, caller);
         local $\ = undef if (defined $\);
         print $_fh $$_data_ref;
      }

      return;
   }

   sub _do_send_init {

      my MCE $self = $_[0];

      @_ = ();

      die "Private method called" unless (caller)[0]->isa( ref($self) );

      $_chn        = $self->{_chn};
      $_DAT_LOCK   = $self->{_dat_lock};
      $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
      $_DAU_W_SOCK = $self->{_dat_w_sock}->[$_chn];
      $_lock_chn   = $self->{_lock_chn};

      $_task_id    = $self->{_task_id};

      return;
   }

   ## -------------------------------------------------------------------------

   sub _do_user_func {

      my MCE $self  = $_[0];
      my $_chunk    = $_[1];
      my $_chunk_id = $_[2];

      $self->{_chunk_id} = $_chunk_id;

      $_user_func->($self, $_chunk, $_chunk_id);

      return;
   }

   sub _do_user_func_init {

      my MCE $self = $_[0];

      $_user_func = $self->{user_func};

      return;
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Do.
##
###############################################################################

sub _worker_do {

   my MCE $self = $_[0]; my $_params_ref = $_[1];

   @_ = ();

   die "Private method called" unless (caller)[0]->isa( ref($self) );

   ## Set options.
   $self->{_abort_msg}  = $_params_ref->{_abort_msg};
   $self->{_run_mode}   = $_params_ref->{_run_mode};
   $self->{_single_dim} = $_params_ref->{_single_dim};
   $self->{use_slurpio} = $_params_ref->{_use_slurpio};
   $self->{parallel_io} = $_params_ref->{_parallel_io};
   $self->{RS}          = $_params_ref->{_RS};

   _do_user_func_init($self);

   ## Init local vars.
   my $_chn        = $self->{_chn};
   my $_DAT_LOCK   = $self->{_dat_lock};
   my $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK = $self->{_dat_w_sock}->[$_chn];
   my $_lock_chn   = $self->{_lock_chn};
   my $_run_mode   = $self->{_run_mode};
   my $_task_id    = $self->{_task_id};
   my $_task_name  = $self->{task_name};

   ## Do not override params if defined in user_tasks during instantiation.
   for (qw(bounds_only chunk_size interval sequence user_args)) {
      if (defined $_params_ref->{"_$_"}) {
         $self->{$_} = $_params_ref->{"_$_"}
            unless (defined $self->{_task}->{$_});
      }
   }

   ## Assign user function.
   $self->{_wuf} = \&_do_user_func;

   ## Set time_block & start_time values for interval.
   if (defined $self->{interval}) {
      my $_i     = $self->{interval};
      my $_delay = $_i->{delay} * $_i->{max_nodes};

      $self->{_i_app_tb} = $_delay * $self->{max_workers};

      $self->{_i_app_st} =
         $_i->{_time} + ($_delay / $_i->{max_nodes} * $_i->{node_id});

      $self->{_i_wrk_st} =
         ($self->{_task_wid} - 1) * $_delay + $self->{_i_app_st};
   }

   ## Call user_begin if defined.
   $self->{user_begin}($self, $_task_id, $_task_name)
      if (defined $self->{user_begin});

   ## Call worker function.
   if ($_run_mode eq 'sequence') {
      require MCE::Core::Input::Sequence
         unless (defined $MCE::Core::Input::Sequence::VERSION);
      _worker_sequence_queue($self);
   }
   elsif (defined $self->{_task}->{sequence}) {
      require MCE::Core::Input::Generator
         unless (defined $MCE::Core::Input::Generator::VERSION);
      _worker_sequence_generator($self);
   }
   elsif ($_run_mode eq 'array') {
      require MCE::Core::Input::Request
         unless (defined $MCE::Core::Input::Request::VERSION);
      _worker_request_chunk($self, REQUEST_ARRAY);
   }
   elsif ($_run_mode eq 'glob') {
      require MCE::Core::Input::Request
         unless (defined $MCE::Core::Input::Request::VERSION);
      _worker_request_chunk($self, REQUEST_GLOB);
   }
   elsif ($_run_mode eq 'iterator') {
      require MCE::Core::Input::Iterator
         unless (defined $MCE::Core::Input::Iterator::VERSION);
      _worker_user_iterator($self);
   }
   elsif ($_run_mode eq 'file') {
      require MCE::Core::Input::Handle
         unless (defined $MCE::Core::Input::Handle::VERSION);
      _worker_read_handle($self, READ_FILE, $_params_ref->{_input_file});
   }
   elsif ($_run_mode eq 'memory') {
      require MCE::Core::Input::Handle
         unless (defined $MCE::Core::Input::Handle::VERSION);
      _worker_read_handle($self, READ_MEMORY, $self->{input_data});
   }
   elsif (defined $self->{user_func}) {
      $self->{_chunk_id} = $self->{_task_wid};
      $self->{user_func}->($self);
   }

   undef $self->{_next_jmp} if (defined $self->{_next_jmp});
   undef $self->{_last_jmp} if (defined $self->{_last_jmp});
   undef $self->{user_data} if (defined $self->{user_data});

   ## Call user_end if defined.
   $self->{user_end}($self, $_task_id, $_task_name)
      if (defined $self->{user_end});

   $_die_msg = undef;

   ## Notify the main process a worker has completed.
   local $\ = undef if (defined $\);

   flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
   print $_DAT_W_SOCK OUTPUT_W_DNE . $LF . $_chn . $LF;
   print $_DAU_W_SOCK $_task_id . $LF;
   flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Loop.
##
###############################################################################

sub _worker_loop {

   my MCE $self = $_[0];

   @_ = ();

   die "Private method called" unless (caller)[0]->isa( ref($self) );

   my ($_response, $_len, $_buffer, $_params_ref);

   my $_COM_LOCK   = $self->{_com_lock};
   my $_COM_W_SOCK = $self->{_com_w_sock};
   my $_job_delay  = $self->{job_delay};
   my $_wid        = $self->{_wid};

   while (1) {

      {
         local $\ = undef; local $/ = $LF;
         flock $_COM_LOCK, LOCK_EX;

         ## Wait until next job request.
         $_response = <$_COM_W_SOCK>;
         print $_COM_W_SOCK $_wid . $LF;

         last unless (defined $_response);
         chomp $_response;

         ## End loop if an invalid reply.
         last if ($_response !~ /\A(?:\d+|_data|_exit)\z/);

         if ($_response eq '_data') {
            ## Acquire and process user data.
            chomp($_len = <$_COM_W_SOCK>);
            read $_COM_W_SOCK, $_buffer, $_len;

            print $_COM_W_SOCK $_wid . $LF;
            flock $_COM_LOCK, LOCK_UN;

            $self->{user_data} = $self->{thaw}($_buffer);
            undef $_buffer;

            select(undef, undef, undef, $_job_delay * $_wid)
               if (defined $_job_delay && $_job_delay > 0.0);

            _worker_do($self, { });
         }
         else {
            ## Return to caller if instructed to exit.
            if ($_response eq '_exit') {
               flock $_COM_LOCK, LOCK_UN;
               return 0;
            }

            ## Retrieve params data.
            chomp($_len = <$_COM_W_SOCK>);
            read $_COM_W_SOCK, $_buffer, $_len;

            print $_COM_W_SOCK $_wid . $LF;
            flock $_COM_LOCK, LOCK_UN;

            $_params_ref = $self->{thaw}($_buffer);
            undef $_buffer;
         }
      }

      ## Start over if the last response was for processing user data.
      next if ($_response eq '_data');

      ## Wait until MCE completes params submission to all workers.
      my $_c; sysread $self->{_bse_r_sock}, $_c, 1;

      select(undef, undef, undef, $_job_delay * $_wid)
         if (defined $_job_delay && $_job_delay > 0.0);

      _worker_do($self, $_params_ref); undef $_params_ref;
   }

   ## Notify the main process a worker has ended. The following is executed
   ## when an invalid reply was received above (not likely to occur).

   flock $_COM_LOCK, LOCK_UN;
   die "worker $self->{_wid} has ended prematurely";

   return 1;
}

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Main.
##
###############################################################################

sub _worker_main {

   my MCE $self = $_[0]; my $_wid      = $_[1]; my $_task   = $_[2];
   my $_task_id = $_[3]; my $_task_wid = $_[4]; my $_params = $_[5];

   my $_plugin_worker_init = $_[6];

   @_ = ();

   ## Commented out -- fails with the 'forks' module under FreeBSD.
   ## die "Private method called" unless (caller)[0]->isa( ref($self) );

   if (exists $self->{input_data}) {
      my $_ref = ref $self->{input_data};
      delete $self->{input_data} if ($_ref && $_ref ne 'SCALAR');
   }

   ## Define status ID.
   my $_use_threads = (defined $_task->{use_threads})
      ? $_task->{use_threads} : $self->{use_threads};

   if ($MCE::_has_threads && $_use_threads) {
      $self->{_exit_pid} = "TID_" . threads->tid();
   } else {
      $self->{_exit_pid} = "PID_" . $$;
   }

   ## Define handlers.
   $SIG{PIPE} = \&MCE::_NOOP;

   $SIG{__DIE__} = sub {
      unless ($MCE::_has_threads && $_use_threads) {
         $_die_msg = (defined $_[0]) ? $_[0] : '';
         CORE::die(@_);
      }
      else {
         CORE::die(@_) unless (defined $^S);
         local $SIG{__DIE__} = sub { };
         local $\ = undef; print STDERR $_[0];
         $self->exit(255, $_[0]);
      }
   };

   ## Use options from user_tasks if defined.
   $self->{max_workers} = $_task->{max_workers} if ($_task->{max_workers});
   $self->{chunk_size}  = $_task->{chunk_size}  if ($_task->{chunk_size});
   $self->{gather}      = $_task->{gather}      if ($_task->{gather});
   $self->{interval}    = $_task->{interval}    if ($_task->{interval});
   $self->{sequence}    = $_task->{sequence}    if ($_task->{sequence});
   $self->{task_name}   = $_task->{task_name}   if ($_task->{task_name});
   $self->{user_args}   = $_task->{user_args}   if ($_task->{user_args});
   $self->{user_begin}  = $_task->{user_begin}  if ($_task->{user_begin});
   $self->{user_func}   = $_task->{user_func}   if ($_task->{user_func});
   $self->{user_end}    = $_task->{user_end}    if ($_task->{user_end});

   ## Init runtime vars. Obtain handle to lock files.
   my $_mce_sid  = $self->{_mce_sid};
   my $_sess_dir = $self->{_sess_dir};

   if (defined $_params && exists $_params->{_chn}) {
      $self->{_chn} = $_params->{_chn}; delete $_params->{_chn};
   } else {
      $self->{_chn} = $_wid % $self->{_data_channels} + 1;
   }

   $self->{_task_id}    = (defined $_task_id ) ? $_task_id  : 0;
   $self->{_task_wid}   = (defined $_task_wid) ? $_task_wid : $_wid;
   $self->{_task}       = $_task;
   $self->{_wid}        = $_wid;

   my ($_COM_LOCK, $_DAT_LOCK);
   my $_lock_chn = $self->{_lock_chn};
   my $_chn      = $self->{_chn};

   for (1 .. $self->{_data_channels}) {
      $self->{_dat_r_sock}->[$_] = $self->{_dat_w_sock}->[$_] = undef
         unless ($_ == $_chn);
   }

   if ($_lock_chn) {
      open $_DAT_LOCK, '+>>:raw:stdio', "$_sess_dir/_dat.lock.$_chn"
         or die "(W) open error $_sess_dir/_dat.lock.$_chn: $!\n";
   }
   open $_COM_LOCK, '+>>:raw:stdio', "$_sess_dir/_com.lock"
      or die "(W) open error $_sess_dir/_com.lock: $!\n";

   $self->{_dat_lock} = $_DAT_LOCK;
   $self->{_com_lock} = $_COM_LOCK;

   ## Delete attributes no longer required after being spawned.
   delete @{ $self }{ qw(
      flush_file flush_stderr flush_stdout stderr_file stdout_file
      on_post_exit on_post_run user_data user_error user_output
      _pids _state _status _thrs _tids
   )};

   foreach (keys %MCE::_mce_spawned) {
      delete $MCE::_mce_spawned{$_} unless ($_ eq $_mce_sid);
   }

   ## Call module's worker_init routine for modules plugged into MCE.
   $_->($self) for (@{ $_plugin_worker_init });

   _do_send_init($self);

   ## Begin processing if worker was added during processing. Otherwise,
   ## respond back to the main process if the last worker spawned.
   if (defined $_params) {
      select(undef, undef, undef, 0.002);
      _worker_do($self, $_params); undef $_params;
   }
   elsif ($self->{_wid} == $self->{_total_workers}) {
      my $_buffer; my $_COM_W_SOCK = $self->{_com_w_sock};
      sysread $self->{_que_r_sock}, $_buffer, 1;
      local $\ = undef; print $_COM_W_SOCK $LF;
   }

   ## Enter worker loop.
   my $_status = _worker_loop($self);

   delete $MCE::_mce_spawned{$_mce_sid};

   ## Wait until MCE completes exit notification.
   $SIG{__DIE__} = $SIG{__WARN__} = sub { };

   eval {
      my $_c; sysread $self->{_bse_r_sock}, $_c, 1;
   };

   select(undef, undef, undef, 0.005) if ($MCE::_is_WinEnv);

   if ($_lock_chn) {
      close $_DAT_LOCK; undef $_DAT_LOCK;
   }

   close $_COM_LOCK; undef $_COM_LOCK;

   select STDERR; $| = 1;
   select STDOUT; $| = 1;

   return;
}

1;

