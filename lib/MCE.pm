###############################################################################
## ----------------------------------------------------------------------------
## MCE - Many-Core Engine for Perl providing parallel processing capabilities.
##
###############################################################################

package MCE;

use strict;
use warnings;

## no critic (BuiltinFunctions::ProhibitStringyEval)
## no critic (Subroutines::ProhibitSubroutinePrototypes)
## no critic (TestingAndDebugging::ProhibitNoStrict)

BEGIN {
   require Carp;

   ## Forking is emulated under the Windows enviornment (excluding Cygwin).
   ## MCE 1.514+ will load the 'threads' module by default on Windows.
   ## Folks may specify use_threads => 0 if threads is not desired.

   if ($^O eq 'MSWin32' && !defined $threads::VERSION) {
      local $@; local $SIG{__DIE__} = \&_NOOP;
      eval 'use threads; use threads::shared';
   }
}

use Fcntl qw( :flock O_RDONLY );
use Socket qw( :crlf PF_UNIX PF_UNSPEC SOCK_STREAM );
use Symbol qw( qualify_to_ref );
use Storable qw( );

use Scalar::Util qw( looks_like_number weaken );
use Time::HiRes qw( sleep time );
use MCE::Signal;
use bytes;

our $VERSION = '1.600';

our ($MCE, $_que_read_size, $_que_template, %_valid_fields_new);
my  ($_is_cygwin, $_is_mswin32, $_is_winenv, $_prev_mce);
my  (%_params_allowed_args, %_valid_fields_task);

BEGIN {
   ## Configure pack/unpack template for writing to and reading from
   ## the queue. Each entry contains 2 positive numbers: chunk_id & msg_id.
   ## Attempt 64-bit size, otherwize fall back to host machine's word length.
   {
      local $@; local $SIG{__DIE__} = \&_NOOP;
      eval { $_que_read_size = length pack('Q2', 0, 0); };
      $_que_template  = ($@) ? 'I2' : 'Q2';
      $_que_read_size = length pack($_que_template, 0, 0);
   }

   ## Attributes used internally.
   ## _abort_msg _chn _com_lock _dat_lock _i_app_st _i_app_tb _i_wrk_st _wuf
   ## _chunk_id _mce_sid _mce_tid _pids _run_mode _single_dim _thrs _tids _wid
   ## _exiting _exit_pid _total_exited _total_running _total_workers _task_wid
   ## _send_cnt _sess_dir _spawned _state _status _task _task_id _wrk_status
   ## _last_sref _init_total_workers _rla_data _rla_return
   ##
   ## _bsb_r_sock _bsb_w_sock _bse_r_sock _bse_w_sock _com_r_sock _com_w_sock
   ## _dat_r_sock _dat_w_sock _que_r_sock _que_w_sock _rla_r_sock _rla_w_sock
   ## _data_channels _lock_chn

   %_valid_fields_new = map { $_ => 1 } qw(
      max_workers tmp_dir use_threads user_tasks task_end task_name freeze thaw
      chunk_size input_data sequence job_delay spawn_delay submit_delay RS
      flush_file flush_stderr flush_stdout stderr_file stdout_file use_slurpio
      interval user_args user_begin user_end user_func user_error user_output
      bounds_only gather init_relay on_post_exit on_post_run parallel_io
   );
   %_params_allowed_args = map { $_ => 1 } qw(
      chunk_size input_data sequence job_delay spawn_delay submit_delay RS
      flush_file flush_stderr flush_stdout stderr_file stdout_file use_slurpio
      interval user_args user_begin user_end user_func user_error user_output
      bounds_only gather init_relay on_post_exit on_post_run parallel_io
   );
   %_valid_fields_task = map { $_ => 1 } qw(
      max_workers chunk_size input_data interval sequence task_end task_name
      bounds_only gather init_relay user_args user_begin user_end user_func
      RS use_slurpio use_threads parallel_io
   );

   $_is_cygwin  = ($^O eq 'cygwin' ) ? 1 : 0;
   $_is_mswin32 = ($^O eq 'MSWin32') ? 1 : 0;
   $_is_winenv  = ($_is_cygwin || $_is_mswin32) ? 1 : 0;

   ## Create accessor functions.
   no strict 'refs'; no warnings 'redefine';

   foreach my $_id (qw( chunk_size max_workers task_name tmp_dir user_args )) {
      *{ $_id } = sub () {
         my $x = shift; my $self = ref($x) ? $x : $MCE;
         return $self->{$_id};
      };
   }
   foreach my $_id (qw( chunk_id sess_dir task_id task_wid wid )) {
      *{ $_id } = sub () {
         my $x = shift; my $self = ref($x) ? $x : $MCE;
         return $self->{"_$_id"};
      };
   }
   foreach my $_id (qw( freeze thaw )) {
      *{ $_id } = sub () {
         my $x = shift; my $self = ref($x) ? $x : $MCE;
         return $self->{$_id}(@_);
      };
   }

   ## PDL + MCE (spawning as threads) is not stable. Thanks to David Mertens
   ## for reporting on how he fixed it for his PDL::Parallel::threads module.

   sub PDL::CLONE_SKIP { return 1; }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Import routine.
##
###############################################################################

use constant { SELF => 0, CHUNK => 1, CID => 2 };

our $_MCE_LOCK : shared = 1;

our $TMP_DIR = $MCE::Signal::tmp_dir;
our $FREEZE  = \&Storable::freeze;
our $THAW    = \&Storable::thaw;

my ($MAX_WORKERS, $CHUNK_SIZE) = (1, 1);
my ($_has_threads, $_loaded);

sub import {

   my $_class = shift; return if ($_loaded++);

   ## Process module arguments.
   while (my $_argument = shift) {
      my $_arg = lc $_argument;

      $MAX_WORKERS = shift and next if ( $_arg eq 'max_workers' );
      $CHUNK_SIZE  = shift and next if ( $_arg eq 'chunk_size' );
      $FREEZE      = shift and next if ( $_arg eq 'freeze' );
      $THAW        = shift and next if ( $_arg eq 'thaw' );

      if ( $_arg eq 'sereal' ) {
         if (shift eq '1') {
            local $@; eval 'use Sereal qw(encode_sereal decode_sereal)';
            unless ($@) {
               $FREEZE = \&encode_sereal;
               $THAW   = \&decode_sereal;
            }
         }
         next;
      }

      if ( $_arg eq 'tmp_dir' ) {
         $TMP_DIR = shift;
         my $_e1 = 'is not a directory or does not exist';
         my $_e2 = 'is not writeable';
         _croak("MCE::import: ($TMP_DIR) $_e1") unless -d $TMP_DIR;
         _croak("MCE::import: ($TMP_DIR) $_e2") unless -w $TMP_DIR;
         next;
      }

      if ( $_arg eq 'export_const' || $_arg eq 'const' ) {
         if (shift eq '1') {
            no strict 'refs'; no warnings 'redefine';
            my $_package = caller;
            *{ $_package . '::SELF'  } = \&SELF;
            *{ $_package . '::CHUNK' } = \&CHUNK;
            *{ $_package . '::CID'   } = \&CID;
         }
         next;
      }

      _croak("MCE::import: ($_argument) is not a valid module argument");
   }

   ## Will spawn threads when threads is present, otherwise processes.
   unless (defined $_has_threads) {
      if (defined $threads::VERSION) {
         unless (defined $threads::shared::VERSION) {
            local $@; local $SIG{__DIE__} = \&_NOOP;
            eval 'use threads::shared; threads::shared::share($_MCE_LOCK)';
         }
         $_has_threads = 1;
      }
      $_has_threads = $_has_threads || 0;
   }

   ## Preload essential modules early on.
   require MCE::Util;
   require MCE::Core::Validation;
   require MCE::Core::Manager;
   require MCE::Core::Worker;

   {
      no strict 'refs'; no warnings 'redefine';
      *{ 'MCE::_parse_max_workers' } = \&MCE::Util::_parse_max_workers;
   }

   ## Instantiate a module-level instance.
   $MCE = MCE->new( _module_instance => 1, max_workers => 0 );

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Define constants & variables.
##
###############################################################################

use constant {

   DATA_CHANNELS  => 8,                  ## Maximum IPC "DATA" channels

   FAST_SEND_SIZE => 1024 * 64 + 128,    ## Use one print call if <  size
   MAX_CHUNK_SIZE => 1024 * 1024 * 64,   ## Maximum chunk size allowed

   MAX_RECS_SIZE  => 8192,               ## Reads # of records if <= value
                                         ## Reads # of bytes   if >  value

   OUTPUT_W_ABT   => 'W~ABT',            ## Worker has aborted
   OUTPUT_W_DNE   => 'W~DNE',            ## Worker has completed
   OUTPUT_W_RLA   => 'W~RLA',            ## Worker has relayed
   OUTPUT_W_EXT   => 'W~EXT',            ## Worker has exited
   OUTPUT_A_ARY   => 'A~ARY',            ## Array  << Array
   OUTPUT_S_GLB   => 'S~GLB',            ## Scalar << Glob FH
   OUTPUT_U_ITR   => 'U~ITR',            ## User   << Iterator
   OUTPUT_A_CBK   => 'A~CBK',            ## Callback w/ multiple args
   OUTPUT_S_CBK   => 'S~CBK',            ## Callback w/ 1 scalar arg
   OUTPUT_N_CBK   => 'N~CBK',            ## Callback w/ no args
   OUTPUT_A_GTR   => 'A~GTR',            ## Gather w/ multiple args
   OUTPUT_R_GTR   => 'R~GTR',            ## Gather w/ 1 reference arg
   OUTPUT_S_GTR   => 'S~GTR',            ## Gather w/ 1 scalar arg
   OUTPUT_O_SND   => 'O~SND',            ## Send >> STDOUT
   OUTPUT_E_SND   => 'E~SND',            ## Send >> STDERR
   OUTPUT_F_SND   => 'F~SND',            ## Send >> File
   OUTPUT_D_SND   => 'D~SND',            ## Send >> File descriptor
   OUTPUT_B_SYN   => 'B~SYN',            ## Barrier sync - begin
   OUTPUT_E_SYN   => 'E~SYN',            ## Barrier sync - end

   READ_FILE      => 0,                  ## Worker reads file handle
   READ_MEMORY    => 1,                  ## Worker reads memory handle

   REQUEST_ARRAY  => 0,                  ## Worker requests next array chunk
   REQUEST_GLOB   => 1,                  ## Worker requests next glob chunk

   SENDTO_FILEV1  => 0,                  ## Worker sends to 'file', $a, '/path'
   SENDTO_FILEV2  => 1,                  ## Worker sends to 'file:/path', $a
   SENDTO_STDOUT  => 2,                  ## Worker sends to STDOUT
   SENDTO_STDERR  => 3,                  ## Worker sends to STDERR
   SENDTO_FD      => 4,                  ## Worker sends to file descriptor

   WANTS_UNDEF    => 0,                  ## Callee wants nothing
   WANTS_ARRAY    => 1,                  ## Callee wants list
   WANTS_SCALAR   => 2,                  ## Callee wants scalar
   WANTS_REF      => 3                   ## Callee wants H/A/S ref
};

my $_mce_count    = 0;
my %_mce_sess_dir = ();
my %_mce_spawned  = ();

MCE::Signal::_set_session_vars(\%_mce_sess_dir, \%_mce_spawned);

sub _clean_sessions {
   my ($_mce_sid) = @_;
   foreach (keys %_mce_spawned) {
      delete $_mce_spawned{$_} unless ($_ eq $_mce_sid);
   }
   return;
}

sub _clear_session {
   my ($_mce_sid) = @_;
   delete $_mce_spawned{$_mce_sid};
   return;
}

## Warnings are disabled to minimize bits of noise when user or OS signals
## the script to exit. e.g. MCE_script.pl < infile | head

no warnings 'threads';
no warnings 'uninitialized';

sub DESTROY { }

###############################################################################
## ----------------------------------------------------------------------------
## Plugin interface for external modules plugging into MCE, e.g. MCE::Queue.
##
###############################################################################

my (%_plugin_function, @_plugin_loop_begin, @_plugin_loop_end);
my (%_plugin_list, @_plugin_worker_init);

sub _attach_plugin {

   my $_ext_module = caller;

   unless (exists $_plugin_list{$_ext_module}) {
      $_plugin_list{$_ext_module} = 1;

      my $_ext_output_function    = $_[0];
      my $_ext_output_loop_begin  = $_[1];
      my $_ext_output_loop_end    = $_[2];
      my $_ext_worker_init        = $_[3];

      return unless (ref $_ext_output_function   eq 'HASH');
      return unless (ref $_ext_output_loop_begin eq 'CODE');
      return unless (ref $_ext_output_loop_end   eq 'CODE');
      return unless (ref $_ext_worker_init       eq 'CODE');

      for (keys %{ $_ext_output_function }) {
         $_plugin_function{$_} = $_ext_output_function->{$_}
            unless (exists $_plugin_function{$_});
      }

      push @_plugin_loop_begin, $_ext_output_loop_begin;
      push @_plugin_loop_end, $_ext_output_loop_end;
      push @_plugin_worker_init, $_ext_worker_init;
   }

   @_ = ();

   return;
}

## Functions for saving and restoring $MCE. This is mainly helpful for
## modules using MCE. e.g. MCE::Map.

sub _save_state {
   $_prev_mce = $MCE;
   return;
}

sub _restore_state {
   $MCE = $_prev_mce; $_prev_mce = undef;
   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## New instance instantiation.
##
###############################################################################

sub new {

   my ($class, %self) = @_;

   @_ = ();

   bless(\%self, ref($class) || $class);

   ## Public options.
   $self{max_workers} ||= $MAX_WORKERS;
   $self{chunk_size}  ||= $CHUNK_SIZE;
   $self{tmp_dir}     ||= $TMP_DIR;
   $self{freeze}      ||= $FREEZE;
   $self{thaw}        ||= $THAW;
   $self{task_name}   ||= 'MCE';

   if (exists $self{_module_instance}) {
      $self{_spawned} = $self{_task_id} = $self{_task_wid} = 0;
      $self{_chunk_id} = $self{_wid} = $self{_wrk_status} = 0;
      delete $self{_module_instance};

      return $MCE = \%self;
   }

   for (keys %self) {
      _croak("MCE::new: ($_) is not a valid constructor argument")
         unless (exists $_valid_fields_new{$_});
   }

   if (defined $self{use_threads}) {
      if (!$_has_threads && $self{use_threads} ne '0') {
         my $_msg  = "\n";
            $_msg .= "## Please include threads support prior to loading MCE\n";
            $_msg .= "## when specifying use_threads => $self{use_threads}\n";
            $_msg .= "\n";

         _croak($_msg);
      }
   }
   else {
      $self{use_threads} = ($_has_threads) ? 1 : 0;
   }

   if ($self{use_threads} && !$MCE::Signal::has_threads) {
      $MCE::Signal::has_threads = 1;
   }

   $self{flush_file}   ||= 0;
   $self{flush_stderr} ||= 0;
   $self{flush_stdout} ||= 0;
   $self{use_slurpio}  ||= 0;
   $self{parallel_io}  ||= 0;

   ## -------------------------------------------------------------------------
   ## Validation.

   _croak("MCE::new: ($self{tmp_dir}) is not a directory or does not exist")
      unless (-d $self{tmp_dir});
   _croak("MCE::new: ($self{tmp_dir}) is not writeable")
      unless (-w $self{tmp_dir});

   if (defined $self{user_tasks}) {
      _croak('MCE::new: (user_tasks) is not an ARRAY reference')
         unless (ref $self{user_tasks} eq 'ARRAY');

      $self{max_workers} = _parse_max_workers($self{max_workers});

      for my $_task (@{ $self{user_tasks} }) {
         for (keys %{ $_task }) {
            _croak("MCE::new: ($_) is not a valid task constructor argument")
               unless (exists $_valid_fields_task{$_});
         }
         $_task->{max_workers} = $self{max_workers}
            unless (defined $_task->{max_workers});
         $_task->{use_threads} = $self{use_threads}
            unless (defined $_task->{use_threads});

         bless($_task, ref(\%self) || \%self);
      }

      ## File locking fails under Cygwin among children and threads.
      ## Must be all children or all threads, not intermixed.
      if ($_is_cygwin) {
         my (%_values, $_value);

         for my $_task (@{ $self{user_tasks} }) {
            $_value = (defined $_task->{use_threads})
               ? $_task->{use_threads} : $self{use_threads};
            $_values{$_value} = '';
         }

         _croak('MCE::new: (cannot mix) use_threads => 0/1 under Cygwin')
            if (keys %_values > 1);
      }
   }

   _validate_args(\%self);

   ## -------------------------------------------------------------------------
   ## Private options. Limit chunk_size.

   $self{_chunk_id}   = 0;       ## Chunk ID
   $self{_send_cnt}   = 0;       ## Number of times data was sent via send
   $self{_spawned}    = 0;       ## Have workers been spawned
   $self{_task_id}    = 0;       ## Task ID, starts at 0 (array index)
   $self{_task_wid}   = 0;       ## Task Worker ID, starts at 1 per task
   $self{_wid}        = 0;       ## MCE Worker ID, starts at 1 per MCE instance
   $self{_wrk_status} = 0;       ## For saving exit status when worker exits

   if ($self{chunk_size} > MAX_CHUNK_SIZE) {
      $self{chunk_size} = MAX_CHUNK_SIZE;
   }

   my $_total_workers = 0;

   if (defined $self{user_tasks}) {
      $_total_workers += $_->{max_workers} for (@{ $self{user_tasks} });
   } else {
      $_total_workers  = $self{max_workers};
   }

   $self{_last_sref} = (ref $self{input_data} eq 'SCALAR')
      ? $self{input_data} : 0;

   $self{_data_channels} = ($_total_workers < DATA_CHANNELS)
      ? $_total_workers : DATA_CHANNELS;

   $self{_lock_chn} = ($_total_workers > DATA_CHANNELS)
      ? 1 : 0;

   return $MCE = \%self;
}

###############################################################################
## ----------------------------------------------------------------------------
## Spawn method.
##
###############################################################################

sub spawn {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   ## To avoid leaking (Scalars leaked: 1) messages (fixed in Perl 5.12.x).
   @_ = ();

   _croak('MCE::spawn: method cannot be called by the worker process')
      if ($self->{_wid});

   ## Return if workers have already been spawned.
   return $self if ($self->{_spawned});

   $MCE = undef;

   lock $_MCE_LOCK if ($_has_threads);            ## Obtain MCE lock.

   my $_die_handler  = $SIG{__DIE__};  $SIG{__DIE__}  = \&_die;
   my $_warn_handler = $SIG{__WARN__}; $SIG{__WARN__} = \&_warn;

   ## Configure tid/sid for this instance here, not in the new method above.
   ## We want the actual thread id in which spawn was called under.
   unless ($self->{_mce_tid}) {
      $self->{_mce_tid} = ($_has_threads) ? threads->tid() : '';
      $self->{_mce_tid} = '' unless (defined $self->{_mce_tid});
      $self->{_mce_sid} = $$ .'.'. $self->{_mce_tid} .'.'. (++$_mce_count);
   }

   my $_mce_sid  = $self->{_mce_sid};
   my $_sess_dir = $self->{_sess_dir};
   my $_tmp_dir  = $self->{tmp_dir};

   ## Create temp dir.
   unless ($_sess_dir) {
      _croak("MCE::spawn: ($_tmp_dir) is not defined")
         if (!defined $_tmp_dir || $_tmp_dir eq '');
      _croak("MCE::spawn: ($_tmp_dir) is not a directory or does not exist")
         unless (-d $_tmp_dir);
      _croak("MCE::spawn: ($_tmp_dir) is not writeable")
         unless (-w $_tmp_dir);

      my $_cnt = 0; $_sess_dir = $self->{_sess_dir} = "$_tmp_dir/$_mce_sid";

      $_sess_dir = $self->{_sess_dir} = "$_tmp_dir/$_mce_sid." . (++$_cnt)
         while ( !(mkdir $_sess_dir, 0770) );

      $_mce_sess_dir{$_sess_dir} = 1;
   }

   ## Obtain lock.
   open my $_COM_LOCK, '+>>:raw:stdio', "$_sess_dir/_com.lock"
      or die "(M) open error $_sess_dir/_com.lock: $!\n";

   flock $_COM_LOCK, LOCK_EX;

   ## -------------------------------------------------------------------------

   my $_data_channels = $self->{_data_channels};
   my $_max_workers   = _get_max_workers($self);
   my $_use_threads   = $self->{use_threads};

   ## Create socket pairs for IPC.
   _create_socket_pair($self, '_bsb_r_sock', '_bsb_w_sock');      ## sync
   _create_socket_pair($self, '_bse_r_sock', '_bse_w_sock');      ## sync
   _create_socket_pair($self, '_com_r_sock', '_com_w_sock');      ## core
   _create_socket_pair($self, '_que_r_sock', '_que_w_sock');      ## core
   _create_socket_pair($self, '_dat_r_sock', '_dat_w_sock', 0);   ## core
   _create_socket_pair($self, '_dat_r_sock', '_dat_w_sock', $_)
      for (1 .. $_data_channels);

   if (defined $self->{init_relay}) {                             ## relay
      _create_socket_pair($self, '_rla_r_sock', '_rla_w_sock', $_)
         for (0 .. $_max_workers - 1);
   }

   ## Place 1 char in one socket to ensure Perl loads required socket modules
   ## prior to spawning. The last worker spawned will perform the read.
   syswrite $self->{_que_w_sock}, $LF;

   ## -------------------------------------------------------------------------

   ## Spawn workers.
   $_mce_spawned{$_mce_sid} = $self;

   $self->{_pids}   = []; $self->{_thrs}  = []; $self->{_tids} = [];
   $self->{_status} = []; $self->{_state} = []; $self->{_task} = [];

   if (!defined $self->{user_tasks}) {
      $self->{_total_workers} = $_max_workers;
      $self->{_init_total_workers} = $_max_workers;

      if (defined $_use_threads && $_use_threads == 1) {
         _dispatch_thread($self, $_) for (1 .. $_max_workers);
      } else {
         _dispatch_child($self, $_) for (1 .. $_max_workers);
      }

      $self->{_task}->[0] = { _total_workers => $_max_workers };

      for (1 .. $_max_workers) {
         keys(%{ $self->{_state}->[$_] }) = 5;
         $self->{_state}->[$_] = {
            _task => undef, _task_id => undef, _task_wid => undef,
            _params => undef, _chn => $_ % $_data_channels + 1
         }
      }
   }
   else {
      my ($_task_id, $_wid);

      $_task_id = $_wid = $self->{_total_workers} = 0;

      $self->{_total_workers} += $_->{max_workers}
         for (@{ $self->{user_tasks} });

      $self->{_init_total_workers} = $self->{_total_workers};

      for my $_task (@{ $self->{user_tasks} }) {
         my $_tsk_use_threads = $_task->{use_threads};

         if (defined $_tsk_use_threads && $_tsk_use_threads == 1) {
            _dispatch_thread($self, ++$_wid, $_task, $_task_id, $_)
               for (1 .. $_task->{max_workers});
         } else {
            _dispatch_child($self, ++$_wid, $_task, $_task_id, $_)
               for (1 .. $_task->{max_workers});
         }

         $_task_id++;
      }

      $_task_id = $_wid = 0;

      for my $_task (@{ $self->{user_tasks} }) {
         $self->{_task}->[$_task_id] = {
            _total_running => 0, _total_workers => $_task->{max_workers}
         };
         for (1 .. $_task->{max_workers}) {
            keys(%{ $self->{_state}->[++$_wid] }) = 5;
            $self->{_state}->[$_wid] = {
               _task => $_task, _task_id => $_task_id, _task_wid => $_,
               _params => undef, _chn => $_wid % $_data_channels + 1
            }
         }

         $_task_id++;
      }
   }

   ## -------------------------------------------------------------------------

   $self->{_com_lock} = $_COM_LOCK;
   $self->{_send_cnt} = 0;
   $self->{_spawned}  = 1;

   ## Await reply from the last worker spawned.
   if ($self->{_total_workers} > 0) {
      local $/ = $LF; local $!; my $_COM_R_SOCK = $self->{_com_r_sock};
      <$_COM_R_SOCK>;
   }

   ## Release lock.
   flock $_COM_LOCK, LOCK_UN;

   $SIG{__DIE__}  = $_die_handler;
   $SIG{__WARN__} = $_warn_handler;

   $MCE = $self;
   return $self;
}

###############################################################################
## ----------------------------------------------------------------------------
## Forchunk, foreach, and forseq methods.
##
###############################################################################

sub forchunk {

   my $x = shift; my $self = ref($x) ? $x : $MCE;
   my $_input_data = $_[0];

   _validate_runstate($self, 'MCE::forchunk');

   my ($_user_func, $_params_ref);

   if (ref $_[1] eq 'HASH') {
      $_user_func = $_[2]; $_params_ref = $_[1];
   } else {
      $_user_func = $_[1]; $_params_ref = {};
   }

   @_ = ();

   _croak('MCE::forchunk: (input_data) is not specified')
      unless (defined $_input_data);
   _croak('MCE::forchunk: (code_block) is not specified')
      unless (defined $_user_func);

   $_params_ref->{input_data} = $_input_data;
   $_params_ref->{user_func}  = $_user_func;

   $self->run(1, $_params_ref);

   return $self;
}

sub foreach {

   my $x = shift; my $self = ref($x) ? $x : $MCE;
   my $_input_data = $_[0];

   _validate_runstate($self, 'MCE::foreach');

   my ($_user_func, $_params_ref);

   if (ref $_[1] eq 'HASH') {
      $_user_func = $_[2]; $_params_ref = $_[1];
   } else {
      $_user_func = $_[1]; $_params_ref = {};
   }

   @_ = ();

   _croak('MCE::foreach: (input_data) is not specified')
      unless (defined $_input_data);
   _croak('MCE::foreach: (code_block) is not specified')
      unless (defined $_user_func);

   $_params_ref->{chunk_size} = 1;
   $_params_ref->{input_data} = $_input_data;
   $_params_ref->{user_func}  = $_user_func;

   $self->run(1, $_params_ref);

   return $self;
}

sub forseq {

   my $x = shift; my $self = ref($x) ? $x : $MCE;
   my $_sequence = $_[0];

   _validate_runstate($self, 'MCE::forseq');

   my ($_user_func, $_params_ref);

   if (ref $_[1] eq 'HASH') {
      $_user_func = $_[2]; $_params_ref = $_[1];
   } else {
      $_user_func = $_[1]; $_params_ref = {};
   }

   @_ = ();

   _croak('MCE::forseq: (sequence) is not specified')
      unless (defined $_sequence);
   _croak('MCE::forseq: (code_block) is not specified')
      unless (defined $_user_func);

   $_params_ref->{sequence}   = $_sequence;
   $_params_ref->{user_func}  = $_user_func;

   $self->run(1, $_params_ref);

   return $self;
}

###############################################################################
## ----------------------------------------------------------------------------
## Process method.
##
###############################################################################

sub process {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   _validate_runstate($self, 'MCE::process');

   my ($_input_data, $_params_ref);

   if (ref $_[0] eq 'HASH') {
      $_input_data = $_[1]; $_params_ref = $_[0];
   } else {
      $_input_data = $_[0]; $_params_ref = $_[1];
   }

   @_ = ();

   ## Set input data.
   if (defined $_input_data) {
      $_params_ref->{input_data} = $_input_data;
   }
   elsif ( !defined $_params_ref->{input_data} &&
           !defined $_params_ref->{sequence} ) {
      _croak('MCE::process: (input_data or sequence) is not specified');
   }

   ## Pass 0 to "not" auto-shutdown after processing.
   $self->run(0, $_params_ref);

   return $self;
}

###############################################################################
## ----------------------------------------------------------------------------
## Restart worker method.
##
###############################################################################

sub restart_worker {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   @_ = ();

   _croak('MCE::restart_worker: method cannot be called by the worker process')
      if ($self->{_wid});

   my $_wid = $self->{_exited_wid};

   my $_params   = $self->{_state}->[$_wid]->{_params};
   my $_task_wid = $self->{_state}->[$_wid]->{_task_wid};
   my $_task_id  = $self->{_state}->[$_wid]->{_task_id};
   my $_task     = $self->{_state}->[$_wid]->{_task};
   my $_chn      = $self->{_state}->[$_wid]->{_chn};

   $_params->{_chn} = $_chn;

   my $_use_threads = (defined $_task_id)
      ? $_task->{use_threads} : $self->{use_threads};

   $self->{_task}->[$_task_id]->{_total_running} += 1 if (defined $_task_id);
   $self->{_task}->[$_task_id]->{_total_workers} += 1 if (defined $_task_id);

   $self->{_total_running} += 1;
   $self->{_total_workers} += 1;

   if (defined $_use_threads && $_use_threads == 1) {
      _dispatch_thread($self, $_wid, $_task, $_task_id, $_task_wid, $_params);
   } else {
      _dispatch_child($self, $_wid, $_task, $_task_id, $_task_wid, $_params);
   }

   sleep 0.001;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Run method.
##
###############################################################################

sub run {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   _croak('MCE::run: method cannot be called by the worker process')
      if ($self->{_wid});

   my ($_auto_shutdown, $_params_ref);

   if (ref $_[0] eq 'HASH') {
      $_auto_shutdown = (defined $_[1]) ? $_[1] : 1;
      $_params_ref    = $_[0];
   } else {
      $_auto_shutdown = (defined $_[0]) ? $_[0] : 1;
      $_params_ref    = $_[1];
   }

   @_ = ();

   my $_has_user_tasks = (defined $self->{user_tasks}) ? 1 : 0;
   my $_requires_shutdown = 0;

   ## Unset params if workers have been sent user_data via send.
   $_params_ref = undef if ($self->{_send_cnt});

   ## Set user_func to NOOP if not specified.
   if (!defined $self->{user_func} && !defined $_params_ref->{user_func}) {
      $self->{user_func} = \&_NOOP;
   }

   ## Set user specified params if specified.
   if (defined $_params_ref && ref $_params_ref eq 'HASH') {
      $_requires_shutdown = _sync_params($self, $_params_ref);
      _validate_args($self);
   }

   ## Shutdown workers if determined by _sync_params or if processing a
   ## scalar reference. Workers need to be restarted in order to pick up
   ## on the new code blocks and/or scalar reference.

   if ($_has_user_tasks) {
      $self->{init_relay} = $self->{user_tasks}->[0]->{init_relay}
         if ($self->{user_tasks}->[0]->{init_relay});
      $self->{input_data} = $self->{user_tasks}->[0]->{input_data}
         if ($self->{user_tasks}->[0]->{input_data});

      $self->{use_slurpio} = $self->{user_tasks}->[0]->{use_slurpio}
         if ($self->{user_tasks}->[0]->{use_slurpio});
      $self->{parallel_io} = $self->{user_tasks}->[0]->{parallel_io}
         if ($self->{user_tasks}->[0]->{parallel_io});

      $self->{RS} = $self->{user_tasks}->[0]->{RS}
         if ($self->{user_tasks}->[0]->{RS});
   }

   $self->shutdown() if ($_requires_shutdown);

   if (ref $self->{input_data} eq 'SCALAR') {
      $self->shutdown() unless $self->{_last_sref} == $self->{input_data};

      $self->{_last_sref} = $self->{input_data};
   }

   ## -------------------------------------------------------------------------

   $self->{_wrk_status} = 0;

   ## Spawn workers.
   $self->spawn() unless ($self->{_spawned});
   return $self   unless ($self->{_total_workers});

   local $SIG{__DIE__}  = \&_die;
   local $SIG{__WARN__} = \&_warn;

   $MCE = $self;

   my ($_input_data, $_input_file, $_input_glob, $_seq);
   my ($_abort_msg, $_first_msg, $_run_mode, $_single_dim);
   my $_chunk_size = $self->{chunk_size};

   $_seq = ($_has_user_tasks && $self->{user_tasks}->[0]->{sequence})
      ? $self->{user_tasks}->[0]->{sequence}
      : $self->{sequence};

   ## Determine run mode for workers.
   if (defined $_seq) {
      my ($_begin, $_end, $_step, $_fmt) = (ref $_seq eq 'ARRAY')
         ? @{ $_seq } : ($_seq->{begin}, $_seq->{end}, $_seq->{step});

      $_chunk_size = $self->{user_tasks}->[0]->{chunk_size}
         if ($_has_user_tasks && $self->{user_tasks}->[0]->{chunk_size});

      $_run_mode  = 'sequence';
      $_abort_msg = int(($_end - $_begin) / $_step / $_chunk_size) + 1;
      $_first_msg = 0;
   }
   elsif (defined $self->{input_data}) {
      my $_ref = ref $self->{input_data};

      if ($_ref eq 'ARRAY') {                        ## Array mode.
         $_run_mode   = 'array';
         $_input_data = $self->{input_data};
         $_input_file = $_input_glob = undef;
         $_single_dim = 1 if (ref $_input_data->[0] eq '');
         $_abort_msg  = 0; ## Flag: Has Data: No
         $_first_msg  = 1; ## Flag: Has Data: Yes

         if (@{ $_input_data } == 0) {
            return $self->shutdown() if ($_auto_shutdown == 1);
         }
      }
      elsif ($_ref eq 'GLOB' || $_ref =~ /^IO::/) {  ## Glob mode.
         $_run_mode   = 'glob';
         $_input_glob = $self->{input_data};
         $_input_data = $_input_file = undef;
         $_abort_msg  = 0; ## Flag: Has Data: No
         $_first_msg  = 1; ## Flag: Has Data: Yes
      }
      elsif ($_ref eq 'CODE') {                      ## Iterator mode.
         $_run_mode   = 'iterator';
         $_input_data = $self->{input_data};
         $_input_file = $_input_glob = undef;
         $_abort_msg  = 0; ## Flag: Has Data: No
         $_first_msg  = 1; ## Flag: Has Data: Yes
      }
      elsif ($_ref eq '') {                          ## File mode.
         $_run_mode   = 'file';
         $_input_file = $self->{input_data};
         $_input_data = $_input_glob = undef;
         $_abort_msg  = (-s $_input_file) + 1;
         $_first_msg  = 0; ## Begin at offset position

         if ((-s $_input_file) == 0) {
            return $self->shutdown() if ($_auto_shutdown == 1);
         }
      }
      elsif ($_ref eq 'SCALAR') {                    ## Memory mode.
         $_run_mode   = 'memory';
         $_input_data = $_input_file = $_input_glob = undef;
         $_abort_msg  = length(${ $self->{input_data} }) + 1;
         $_first_msg  = 0; ## Begin at offset position

         if (length(${ $self->{input_data} }) == 0) {
            return $self->shutdown() if ($_auto_shutdown == 1);
         }
      }
      else {
         _croak('MCE::run: (input_data) is not valid');
      }
   }
   else {                                            ## Nodata mode.
      $_run_mode  = 'nodata';
      $_abort_msg = undef;
   }

   ## -------------------------------------------------------------------------

   my $_COM_LOCK      = $self->{_com_lock};
   my $_bounds_only   = $self->{bounds_only};
   my $_interval      = $self->{interval};
   my $_sequence      = $self->{sequence};
   my $_user_args     = $self->{user_args};
   my $_use_slurpio   = $self->{use_slurpio};
   my $_parallel_io   = $self->{parallel_io};
   my $_sess_dir      = $self->{_sess_dir};
   my $_total_workers = $self->{_total_workers};
   my $_send_cnt      = $self->{_send_cnt};
   my $_RS            = $self->{RS};

   ## Begin processing.
   unless ($_send_cnt) {

      my %_params = (
         '_abort_msg'   => $_abort_msg,    '_run_mode'    => $_run_mode,
         '_chunk_size'  => $_chunk_size,   '_single_dim'  => $_single_dim,
         '_input_file'  => $_input_file,   '_interval'    => $_interval,
         '_sequence'    => $_sequence,     '_bounds_only' => $_bounds_only,
         '_use_slurpio' => $_use_slurpio,  '_parallel_io' => $_parallel_io,
         '_user_args'   => $_user_args,    '_RS'          => $_RS,
      );
      my %_params_nodata = (
         '_abort_msg'   => undef,          '_run_mode'    => 'nodata',
         '_chunk_size'  => $_chunk_size,   '_single_dim'  => $_single_dim,
         '_input_file'  => $_input_file,   '_interval'    => $_interval,
         '_sequence'    => $_sequence,     '_bounds_only' => $_bounds_only,
         '_use_slurpio' => $_use_slurpio,  '_parallel_io' => $_parallel_io,
         '_user_args'   => $_user_args,    '_RS'          => $_RS,
      );

      local $\ = undef; local $/ = $LF;
      lock $_MCE_LOCK if ($_has_threads);            ## Obtain MCE lock.

      my ($_wid, %_task0_wids);

      my $_BSE_W_SOCK    = $self->{_bse_w_sock};
      my $_COM_R_SOCK    = $self->{_com_r_sock};
      my $_submit_delay  = $self->{submit_delay};
      my $_frozen_params = $self->{freeze}(\%_params);
      my $_frozen_nodata;

      $_frozen_nodata = $self->{freeze}(\%_params_nodata) if ($_has_user_tasks);

      if ($_has_user_tasks) { for (1 .. @{ $self->{_state} } - 1) {
         $_task0_wids{$_} = 1 unless ($self->{_state}->[$_]->{_task_id});
      }}

      ## Insert the first message into the queue if defined.
      if (defined $_first_msg) {
         my $_QUE_W_SOCK = $self->{_que_w_sock};
         syswrite $_QUE_W_SOCK, pack($_que_template, 0, $_first_msg);
      }

      ## Submit params data to workers.
      for (1 .. $_total_workers) {
         print {$_COM_R_SOCK} $_ . $LF;
         chomp($_wid = <$_COM_R_SOCK>);

         if (!$_has_user_tasks || exists $_task0_wids{$_wid}) {
            print {$_COM_R_SOCK} length($_frozen_params) . $LF . $_frozen_params;
            $self->{_state}->[$_wid]->{_params} = \%_params;
         } else {
            print {$_COM_R_SOCK} length($_frozen_nodata) . $LF . $_frozen_nodata;
            $self->{_state}->[$_wid]->{_params} = \%_params_nodata;
         }

         <$_COM_R_SOCK>;

         sleep 0.003 if ($_is_winenv);

         if (defined $_submit_delay && $_submit_delay > 0.0) {
            sleep $_submit_delay;
         }
      }

      sleep 0.005 if ($_is_winenv);

      ## Obtain lock.
      flock $_COM_LOCK, LOCK_EX;

      syswrite $_BSE_W_SOCK, $LF for (1 .. $_total_workers);

      if (($self->{_mce_tid} ne '' && $self->{_mce_tid} ne '0') || $_is_winenv) {
         sleep 0.002;
      }
   }

   ## -------------------------------------------------------------------------

   $self->{_total_exited} = 0;

   if ($_send_cnt) {
      $self->{_total_running} = $_send_cnt;
      $self->{_task}->[0]->{_total_running} = $_send_cnt;
   }
   else {
      $self->{_total_running} = $_total_workers;
      if (defined $self->{user_tasks}) {
         $_->{_total_running} = $_->{_total_workers} for (@{ $self->{_task} });
      }
   }

   ## Call the output function.
   if ($self->{_total_running} > 0) {
      $self->{_abort_msg}  = $_abort_msg;
      $self->{_run_mode}   = $_run_mode;
      $self->{_single_dim} = $_single_dim;

      _output_loop( $self, $_input_data, $_input_glob,
         \%_plugin_function, \@_plugin_loop_begin, \@_plugin_loop_end
      );

      undef $self->{_abort_msg};
      undef $self->{_run_mode};
      undef $self->{_single_dim};
   }

   unless ($_send_cnt) {
      ## Remove the last message from the queue.
      unless ($_run_mode eq 'nodata') {
         if (defined $self->{_que_r_sock}) {
            my $_next; my $_QUE_R_SOCK = $self->{_que_r_sock};
            sysread $_QUE_R_SOCK, $_next, $_que_read_size;
         }
      }

      ## Release lock.
      flock $_COM_LOCK, LOCK_UN;
   }

   $self->{_send_cnt} = 0;

   ## Shutdown workers (also, if any workers have exited or in eval state).
   if ($_auto_shutdown == 1 || $self->{_total_exited} > 0 || $^S) {
      $self->shutdown();
   }

   return $self;
}

###############################################################################
## ----------------------------------------------------------------------------
## Send method.
##
###############################################################################

sub send {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   _croak('MCE::send: method cannot be called by the worker process')
      if ($self->{_wid});
   _croak('MCE::send: method cannot be called while running')
      if ($self->{_total_running});

   _croak('MCE::send: method cannot be used with input_data or sequence')
      if (defined $self->{input_data} || defined $self->{sequence});
   _croak('MCE::send: method cannot be used with user_tasks')
      if (defined $self->{user_tasks});

   my $_data_ref;

   if (ref $_[0] eq 'ARRAY' || ref $_[0] eq 'HASH' || ref $_[0] eq 'PDL') {
      $_data_ref = $_[0];
   } else {
      _croak('MCE::send: ARRAY, HASH, or a PDL reference is not specified');
   }

   @_ = ();

   $self->{_send_cnt} = 0 unless (defined $self->{_send_cnt});

   ## -------------------------------------------------------------------------

   ## Spawn workers.
   $self->spawn() unless ($self->{_spawned});

   _croak('MCE::send: Sending greater than # of workers is not allowed')
      if ($self->{_send_cnt} >= $self->{_task}->[0]->{_total_workers});

   local $SIG{__DIE__}  = \&_die;
   local $SIG{__WARN__} = \&_warn;

   ## Begin data submission.
   {
      local $\ = undef; local $/ = $LF;

      my $_COM_R_SOCK   = $self->{_com_r_sock};
      my $_sess_dir     = $self->{_sess_dir};
      my $_submit_delay = $self->{submit_delay};
      my $_frozen_data  = $self->{freeze}($_data_ref);
      my $_len          = length $_frozen_data;

      ## Submit data to worker.
      print {$_COM_R_SOCK} '_data' . $LF;
      <$_COM_R_SOCK>;

      if ($_len < FAST_SEND_SIZE) {
         print {$_COM_R_SOCK} $_len . $LF . $_frozen_data;
      } else {
         print {$_COM_R_SOCK} $_len . $LF;
         print {$_COM_R_SOCK} $_frozen_data;
      }

      <$_COM_R_SOCK>;

      if (defined $_submit_delay && $_submit_delay > 0.0) {
         sleep $_submit_delay;
      }

      sleep 0.002 if ($_is_cygwin);
   }

   $self->{_send_cnt} += 1;

   return $self;
}

###############################################################################
## ----------------------------------------------------------------------------
## Shutdown method.
##
###############################################################################

sub shutdown {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   @_ = ();

   ## Return if workers have not been spawned or have already been shutdown.
   return unless (defined $MCE::Signal::tmp_dir);
   return unless ($self->{_spawned});

   ## Wait for workers to complete processing before shutting down.
   _validate_runstate($self, 'MCE::shutdown');
   $self->run(0) if ($self->{_send_cnt});

   local $SIG{__DIE__}  = \&_die;
   local $SIG{__WARN__} = \&_warn;

   lock $_MCE_LOCK if ($_has_threads);            ## Obtain MCE lock.

   my $_is_mce_thr     = ($self->{_mce_tid} ne '' && $self->{_mce_tid} ne '0');
   my $_COM_R_SOCK     = $self->{_com_r_sock};
   my $_data_channels  = $self->{_data_channels};
   my $_mce_sid        = $self->{_mce_sid};
   my $_sess_dir       = $self->{_sess_dir};
   my $_total_workers  = $self->{_total_workers};
   my $_lock_chn       = $self->{_lock_chn};

   ## Delete entry.
   delete $_mce_spawned{$_mce_sid};

   ## Notify workers to exit loop.
   local ($!, $?); local $\ = undef; local $/ = $LF;

   for (1 .. $_total_workers) {
      print {$_COM_R_SOCK} '_exit' . $LF;
      <$_COM_R_SOCK>;
   }

   CORE::shutdown $self->{_bse_w_sock}, 2;        ## Barrier end channels
   CORE::shutdown $self->{_bse_r_sock}, 2;

   ## Reap children/threads.
   if ( $self->{_pids} && @{ $self->{_pids} } > 0 ) {
      my $_list = $self->{_pids};
      for my $i (0 .. @{ $_list }) {
         waitpid $_list->[$i], 0 if ($_list->[$i]);
      }
   }
   elsif ( $self->{_thrs} && @{ $self->{_thrs} } > 0 ) {
      my $_list = $self->{_thrs};
      for my $i (0 .. @{ $_list }) {
         ${ $_list->[$i] }->join() if ($_list->[$i]);
      }
   }

   close $self->{_com_lock}; undef $self->{_com_lock};

   ## -------------------------------------------------------------------------

   ## Close sockets.
   for (qw( _bsb_w_sock _bsb_r_sock _com_w_sock _com_r_sock _que_w_sock
            _que_r_sock _dat_w_sock _dat_r_sock _rla_w_sock _rla_r_sock
   )) {
      if (defined $self->{$_}) {
         if (ref $self->{$_} eq 'ARRAY') {
            for my $_s (@{ $self->{$_} }) { CORE::shutdown $_s, 2; }
         } else {
            CORE::shutdown $self->{$_}, 2;
         }
      }
   }
   for (qw( _bsb_w_sock _bsb_r_sock _com_w_sock _com_r_sock _que_w_sock
            _que_r_sock _dat_w_sock _dat_r_sock _rla_w_sock _rla_r_sock
            _bse_w_sock _bse_r_sock
   )) {
      if (defined $self->{$_}) {
         if (ref $self->{$_} eq 'ARRAY') {
            for my $_s (@{ $self->{$_} }) { close $_s; }
            undef $self->{$_};
         } else {
            close $self->{$_}; undef $self->{$_};
         }
      }
   }

   ## -------------------------------------------------------------------------

   ## Remove session directory.
   if (defined $_sess_dir) {
      unlink "$_sess_dir/_dat.lock.e"
         if (-e "$_sess_dir/_dat.lock.e");

      if ($_lock_chn) {
         unlink "$_sess_dir/_dat.lock.$_" for (1 .. $_data_channels);
      }
      unlink "$_sess_dir/_com.lock";
      rmdir  "$_sess_dir";

      delete $_mce_sess_dir{$_sess_dir};
   }

   ## Reset instance.
   @{$self->{_pids}}   = (); @{$self->{_thrs}}  = (); @{$self->{_tids}} = ();
   @{$self->{_status}} = (); @{$self->{_state}} = (); @{$self->{_task}} = ();

   $self->{_mce_sid}  = $self->{_mce_tid}  = $self->{_sess_dir} = undef;
   $self->{_chunk_id} = $self->{_send_cnt} = $self->{_spawned}  = 0;

   sleep($_is_winenv ? 0.082 : 0.008) if ($_is_mce_thr);

   $self->{_total_running} = $self->{_total_workers} = 0;
   $self->{_total_exited}  = $self->{_last_sref}     = 0;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Barrier sync method.
##
###############################################################################

sub sync {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   _croak('MCE::sync: method cannot be called by the manager process')
      unless ($self->{_wid});

   ## Barrier synchronization is supported for task 0 at this time.
   ## Note: Workers are assigned task_id 0 when omitting user_tasks.

   return if ($self->{_task_id} > 0);

   my $_chn        = $self->{_chn};
   my $_DAT_LOCK   = $self->{_dat_lock};
   my $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
   my $_BSB_R_SOCK = $self->{_bsb_r_sock};
   my $_BSE_R_SOCK = $self->{_bse_r_sock};
   my $_lock_chn   = $self->{_lock_chn};
   my $_buffer;

   local $\ = undef if (defined $\); local $/ = $LF if (!$/ || $/ ne $LF);

   ## Notify the manager process (begin).
   flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
   print {$_DAT_W_SOCK} OUTPUT_B_SYN . $LF . $_chn . $LF;
   flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

   ## Wait here until all workers (task_id 0) have synced.
   sysread $_BSB_R_SOCK, $_buffer, 1;

   ## Notify the manager process (end).
   flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
   print {$_DAT_W_SOCK} OUTPUT_E_SYN . $LF . $_chn . $LF;
   flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

   ## Wait here until all workers (task_id 0) have un-synced.
   sysread $_BSE_R_SOCK, $_buffer, 1;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Yield method.
##
###############################################################################

sub yield {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   return unless ($self->{_i_wrk_st});
   return unless ($self->{_task_wid});

   my $_delay = $self->{_i_wrk_st} - time;
   my $_count;

   if ($_delay < 0.0) {
      $_count  = int($_delay * -1 / $self->{_i_app_tb} + 0.5) + 1;
      $_delay += $self->{_i_app_tb} * $_count;
   }

   sleep $_delay if ($_delay > 0.0);

   if ($_count && $_count > 2_000_000_000) {
      $self->{_i_wrk_st} = time;
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Miscellaneous methods: abort exit last next status.
##
###############################################################################

## Abort current job.

sub abort {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   my $_QUE_R_SOCK = $self->{_que_r_sock};
   my $_QUE_W_SOCK = $self->{_que_w_sock};
   my $_abort_msg  = $self->{_abort_msg};
   my $_lock_chn   = $self->{_lock_chn};

   if (defined $_abort_msg) {
      local $\ = undef;

      if ($_abort_msg > 0) {
         my $_next; sysread $_QUE_R_SOCK, $_next, $_que_read_size;
         syswrite $_QUE_W_SOCK, pack($_que_template, 0, $_abort_msg);
      }

      if ($self->{_wid} > 0) {
         my $_chn        = $self->{_chn};
         my $_DAT_LOCK   = $self->{_dat_lock};
         my $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
         my $_DAU_W_SOCK = $self->{_dat_w_sock}->[$_chn];

         flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);

         if (exists $self->{_rla_return}) {
            print {$_DAT_W_SOCK} OUTPUT_W_RLA . $LF . $_chn . $LF;
            print {$_DAU_W_SOCK} (delete $self->{_rla_return}) . $LF;
         }

         print {$_DAT_W_SOCK} OUTPUT_W_ABT . $LF . $_chn . $LF;

         flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
      }
   }

   return;
}

## Worker exits from MCE.

sub exit {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   my $_exit_status = (defined $_[0]) ? $_[0] : $?;
   my $_exit_msg    = (defined $_[1]) ? $_[1] : '';
   my $_exit_id     = (defined $_[2]) ? $_[2] : '';

   @_ = ();

   _croak('MCE::exit: method cannot be called by the manager process')
      unless ($self->{_wid});

   delete $_mce_spawned{ $self->{_mce_sid} };

   my $_chn        = $self->{_chn};
   my $_COM_LOCK   = $self->{_com_lock};
   my $_DAT_LOCK   = $self->{_dat_lock};
   my $_DAT_W_SOCK = $self->{_dat_w_sock}->[0];
   my $_DAU_W_SOCK = $self->{_dat_w_sock}->[$_chn];
   my $_lock_chn   = $self->{_lock_chn};
   my $_task_id    = $self->{_task_id};
   my $_sess_dir   = $self->{_sess_dir};

   unless ($self->{_exiting}) {
      $self->{_exiting} = 1;

      local $\ = undef if (defined $\);
      my $_len = length $_exit_msg;

      $_exit_id =~ s/[\r\n][\r\n]*/ /mg;

      open my $_DAE_LOCK, '+>>:raw:stdio', "$_sess_dir/_dat.lock.e"
         or die "(W) open error $_sess_dir/_dat.lock.e: $!\n";

      flock $_DAE_LOCK, LOCK_EX;
      sleep 0.05 if ($_is_winenv);

      flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);

      if (exists $self->{_rla_return}) {
         print {$_DAT_W_SOCK} OUTPUT_W_RLA . $LF . $_chn . $LF;
         print {$_DAU_W_SOCK} (delete $self->{_rla_return}) . $LF;
      }

      print {$_DAT_W_SOCK} OUTPUT_W_EXT . $LF . $_chn . $LF;
      print {$_DAU_W_SOCK}
         $_task_id . $LF . $self->{_wid} . $LF . $self->{_exit_pid} . $LF .
         $_exit_status . $LF . $_exit_id . $LF . $_len . $LF . $_exit_msg
      ;

      flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
      flock $_DAE_LOCK, LOCK_UN;

      close $_DAE_LOCK; undef $_DAE_LOCK;
   }

   ## Exit thread/child process.
   $SIG{__DIE__} = $SIG{__WARN__} = sub { };

   select STDERR; $| = 1;
   select STDOUT; $| = 1;

   if ($_lock_chn) {
      close $_DAT_LOCK; undef $_DAT_LOCK;
   }

   close $_COM_LOCK; undef $_COM_LOCK;

   threads->exit($_exit_status)
      if ($_has_threads && threads->can('exit'));

   CORE::kill(9, $$) unless $_is_winenv;
   CORE::exit($_exit_status);

   return;
}

## Worker immediately exits the chunking loop.

sub last {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   _croak('MCE::last: method cannot be called by the manager process')
      unless ($self->{_wid});

   $self->{_last_jmp}() if (defined $self->{_last_jmp});

   return;
}

## Worker starts the next iteration of the chunking loop.

sub next {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   _croak('MCE::next: method cannot be called by the manager process')
      unless ($self->{_wid});

   $self->{_next_jmp}() if (defined $self->{_next_jmp});

   return;
}

## Return the exit status. "_wrk_status" holds the greatest exit status
## among workers exiting.

sub status {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   _croak('MCE::status: method cannot be called by the worker process')
      if ($self->{_wid});

   return (defined $self->{_wrk_status}) ? $self->{_wrk_status} : 0;
}

###############################################################################
## ----------------------------------------------------------------------------
## Methods for serializing data from workers to the main process.
##
###############################################################################

## Do method. Additional arguments are optional.

sub do {

   my $x = shift; my $self = ref($x) ? $x : $MCE;
   my $_callback = shift;

   _croak('MCE::do: method cannot be called by the manager process')
      unless ($self->{_wid});
   _croak('MCE::do: (callback) is not specified')
      unless (defined $_callback);

   $_callback = "main::$_callback" if (index($_callback, ':') < 0);

   return _do_callback($self, $_callback, @_);
}

## Gather method.

sub gather {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   _croak('MCE::gather: method cannot be called by the manager process')
      unless ($self->{_wid});

   return _do_gather($self, @_);
}

## Sendto method.

{
   my %_sendto_lkup = (
      'file'   => SENDTO_FILEV1, 'FILE'   => SENDTO_FILEV1,
      'file:'  => SENDTO_FILEV2, 'FILE:'  => SENDTO_FILEV2,
      'stdout' => SENDTO_STDOUT, 'STDOUT' => SENDTO_STDOUT,
      'stderr' => SENDTO_STDERR, 'STDERR' => SENDTO_STDERR,
      'fd:'    => SENDTO_FD,     'FD:'    => SENDTO_FD,
   );

   my $_v2_regx = qr/^([^:]+:)(.+)/;

   sub sendto {

      my $x = shift; my $self = ref($x) ? $x : $MCE;
      my $_to = shift;

      _croak('MCE::sendto: method cannot be called by the manager process')
         unless ($self->{_wid});

      return unless (defined $_[0]);

      my ($_dest, $_value);
      $_dest = (exists $_sendto_lkup{$_to}) ? $_sendto_lkup{$_to} : undef;

      if (!defined $_dest) {
         if (ref $_to && defined (my $_fd = fileno($_to))) {
            my $_data_ref = (scalar @_ == 1) ? \$_[0] : \join('', @_);
            return _do_send_glob($self, $_to, $_fd, $_data_ref);
         }
         if (defined $_to && $_to =~ /$_v2_regx/o) {
            $_dest  = (exists $_sendto_lkup{$1}) ? $_sendto_lkup{$1} : undef;
            $_value = $2;
         }
         if ( !defined $_dest || ( !defined $_value && (
               $_dest == SENDTO_FILEV2 || $_dest == SENDTO_FD
         ))) {
            my $_msg  = "\n";
               $_msg .= "MCE::sendto: improper use of method\n";
               $_msg .= "\n";
               $_msg .= "## usage:\n";
               $_msg .= "##    ->sendto(\"stderr\", ...);\n";
               $_msg .= "##    ->sendto(\"stdout\", ...);\n";
               $_msg .= "##    ->sendto(\"file:/path/to/file\", ...);\n";
               $_msg .= "##    ->sendto(\"fd:2\", ...);\n";
               $_msg .= "\n";

            _croak($_msg);
         }
      }

      if ($_dest == SENDTO_FILEV1) {              ## sendto 'file', $a, $path
         return if (!defined $_[1] || @_ > 2);    ## Please switch to using V2
         $_value = $_[1]; delete $_[1];           ## sendto 'file:/path', $a
         $_dest  = SENDTO_FILEV2;
      }

      return _do_send($self, $_dest, $_value, @_);
   }
}

###############################################################################
## ----------------------------------------------------------------------------
## Functions for serializing print, printf and say statements.
##
###############################################################################

sub print {

   my $x = shift; my $self = ref($x) ? $x : $MCE;
   my $_fd = 0; my ($_glob, $_data_ref);

   if (ref $_[0] && defined ($_fd = fileno($_[0]))) {
      $_glob = shift;
   }

   if (scalar @_ == 1  ) {
      $_data_ref = \$_[0];
   } elsif (scalar @_ > 1) {
      $_data_ref = \join('', @_);
   } else {
      $_data_ref = \$_;
   }

   return _do_send_glob($self, $_glob, $_fd, $_data_ref) if $_fd;
   return _do_send($self, SENDTO_STDOUT, undef, $_data_ref) if $self->{_wid};
   return _do_send_glob($self, \*STDOUT, 1, $_data_ref);
}

sub printf {

   my $x = shift; my $self = ref($x) ? $x : $MCE;
   my $_fd = 0; my ($_glob, $_fmt, $_data);

   if (ref $_[0] && defined ($_fd = fileno($_[0]))) {
      $_glob = shift;
   }

   $_fmt  = shift || '%s';
   $_data = (scalar @_) ? sprintf($_fmt, @_) : sprintf($_fmt, $_);

   return _do_send_glob($self, $_glob, $_fd, \$_data) if $_fd;
   return _do_send($self, SENDTO_STDOUT, undef, \$_data) if $self->{_wid};
   return _do_send_glob($self, \*STDOUT, 1, \$_data);
}

sub say {

   my $x = shift; my $self = ref($x) ? $x : $MCE;
   my $_fd = 0; my ($_glob, $_data);

   if (ref $_[0] && defined ($_fd = fileno($_[0]))) {
      $_glob = shift;
   }

   $_data = (scalar @_) ? join("\n", @_) . "\n" : $_ . "\n";

   return _do_send_glob($self, $_glob, $_fd, \$_data) if $_fd;
   return _do_send($self, SENDTO_STDOUT, undef, \$_data) if $self->{_wid};
   return _do_send_glob($self, \*STDOUT, 1, \$_data);
}

###############################################################################
## ----------------------------------------------------------------------------
## Relay methods.
##
###############################################################################

sub relay_final {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   _croak('MCE::relay_final: method cannot be called by the worker process')
      if ($self->{_wid});

   if (exists $self->{_rla_return}) {
      if (ref $self->{_rla_return} eq '') {
         return delete $self->{_rla_return};
      }
      elsif (ref $self->{_rla_return} eq 'HASH') {
         return %{ delete $self->{_rla_return} };
      }
      elsif (ref $self->{_rla_return} eq 'ARRAY') {
         return @{ delete $self->{_rla_return} };
      }
   }

   return;
}

sub relay_recv {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   _croak('MCE::relay: method cannot be called by the manager process')
      unless ($self->{_wid});
   _croak('MCE::relay: method cannot be called by this sub task')
      if ($self->{_task_id} > 0);
   _croak('MCE::relay: init_relay is not specified')
      unless (defined $self->{init_relay});

   my $_chn = ($self->{_chunk_id} - 1) % $self->{max_workers};
   my $_rdr = $self->{_rla_r_sock}->[$_chn];

   my ($_len, $_ref); local $_;

   chomp($_len = <$_rdr>);
   read $_rdr, $_, $_len;
   $_ref = chop $_;

   if ($_ref == 0) {                                 ## scalar value
      $self->{_rla_data} = $_;
      return unless defined wantarray;
      return $self->{_rla_data};
   }
   elsif ($_ref == 1) {                              ## hash reference
      $self->{_rla_data} = $self->{thaw}($_);
      return unless defined wantarray;
      return %{ $self->{_rla_data} };
   }
   elsif ($_ref == 2) {                              ## array reference
      $self->{_rla_data} = $self->{thaw}($_);
      return unless defined wantarray;
      return @{ $self->{_rla_data} };
   }

   return;
}

sub relay (;&) {

   my ($self, $_code);

   if (ref $_[0] eq 'CODE') {
      ($self, $_code) = ($MCE, shift);
   } else {
      my $x = shift; $self = ref($x) ? $x : $MCE;
      $_code = shift;
   }

   _croak('MCE::relay: method cannot be called by the manager process')
      unless ($self->{_wid});
   _croak('MCE::relay: method cannot be called by this sub task')
      if ($self->{_task_id} > 0);
   _croak('MCE::relay: init_relay is not specified')
      unless (defined $self->{init_relay});

   if (ref $_code ne 'CODE') {
      _croak('MCE::relay: argument is not a code block') if (defined $_code);
   } else {
      weaken $_code;
   }

   my $_chn = ($self->{_chunk_id} - 1) % $self->{max_workers};
   my $_nxt = $_chn + 1; $_nxt = 0 if ($_nxt == $self->{max_workers});
   my $_rdr = $self->{_rla_r_sock}->[$_chn];
   my $_wtr = $self->{_rla_w_sock}->[$_nxt];

   $self->{_rla_return} = $self->{_chunk_id} .':'. $_nxt;

   if (exists $self->{_rla_data}) {
      local $_ = delete $self->{_rla_data};
      $_code->() if (ref $_code eq 'CODE');

      if (ref $_ eq '') {                         ## scalar value
         my $_tmp = $_ . '0';
         print {$_wtr} length($_tmp) . $LF . $_tmp;
      }
      elsif (ref $_ eq 'HASH') {                  ## hash reference
         my $_tmp = $self->{freeze}($_) . '1';
         print {$_wtr} length($_tmp) . $LF . $_tmp;
      }
      elsif (ref $_ eq 'ARRAY') {                 ## array reference
         my $_tmp = $self->{freeze}($_) . '2';
         print {$_wtr} length($_tmp) . $LF . $_tmp;
      }
   }
   else {
      my ($_len, $_ref); local $_;

      chomp($_len = <$_rdr>);
      read $_rdr, $_, $_len;
      $_ref = chop $_;

      if ($_ref == 0) {                              ## scalar value
         my $_ret = $_;         $_code->() if (ref $_code eq 'CODE');
         my $_tmp = $_ . '0';
         print {$_wtr} length($_tmp) . $LF . $_tmp;
         return unless defined wantarray;
         return $_ret;
      }
      elsif ($_ref == 1) {                           ## hash reference
         my %_ret = %{ $self->{thaw}($_) };
         local $_ = { %_ret };  $_code->() if (ref $_code eq 'CODE');
         my $_tmp = $self->{freeze}($_) . '1';
         print {$_wtr} length($_tmp) . $LF . $_tmp;
         return unless defined wantarray;
         return %_ret;
      }
      elsif ($_ref == 2) {                           ## array reference
         my @_ret = @{ $self->{thaw}($_) };
         local $_ = [ @_ret ];  $_code->() if (ref $_code eq 'CODE');
         my $_tmp = $self->{freeze}($_) . '2';
         print {$_wtr} length($_tmp) . $LF . $_tmp;
         return unless defined wantarray;
         return @_ret;
      }
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods.
##
###############################################################################

sub _NOOP { }

sub _die  { return MCE::Signal->_die_handler(@_); }
sub _warn { return MCE::Signal->_warn_handler(@_); }

sub _croak {

   $\ = undef;

   if (MCE->wid == 0 || ! $^S) {
      $SIG{__DIE__}  = \&MCE::_die;
      $SIG{__WARN__} = \&MCE::_warn;
   }

   goto &Carp::croak;
}

sub _get_max_workers {

   my $x = shift; my $self = ref($x) ? $x : $MCE;

   if (defined $self->{user_tasks}) {
      if (defined $self->{user_tasks}->[0]->{max_workers}) {
         return $self->{user_tasks}->[0]->{max_workers};
      }
   }

   return $self->{max_workers};
}

###############################################################################
## ----------------------------------------------------------------------------
## Create socket pair.
##
###############################################################################

sub _create_socket_pair {

   my ($self, $_r_sock, $_w_sock, $_i) = @_;

   local $!;

   die 'Private method called' unless (caller)[0]->isa( ref $self );

   if (defined $_i) {
      socketpair( $self->{$_r_sock}->[$_i], $self->{$_w_sock}->[$_i],
         PF_UNIX, SOCK_STREAM, PF_UNSPEC ) or die "socketpair: $!\n";

      binmode $self->{$_r_sock}->[$_i];
      binmode $self->{$_w_sock}->[$_i];

      ## Autoflush handles.
      my $_old_hndl = select $self->{$_r_sock}->[$_i]; $| = 1;
                      select $self->{$_w_sock}->[$_i]; $| = 1;

      select $_old_hndl;
   }
   else {
      socketpair( $self->{$_r_sock}, $self->{$_w_sock},
         PF_UNIX, SOCK_STREAM, PF_UNSPEC ) or die "socketpair: $!\n";

      binmode $self->{$_r_sock};
      binmode $self->{$_w_sock};

      ## Autoflush handles.
      my $_old_hndl = select $self->{$_r_sock}; $| = 1;
                      select $self->{$_w_sock}; $| = 1;

      select $_old_hndl;
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Sync methods.
##
###############################################################################

sub _sync_buffer_to_array {

   my ($_buffer_ref, $_array_ref, $_chop_str) = @_;

   local $_; my $_cnt = 0;

   open my $_MEM_FILE, '<', $_buffer_ref;
   binmode $_MEM_FILE;

   unless (length $_chop_str) {
      $_array_ref->[$_cnt++] = $_ while (<$_MEM_FILE>);
   }
   else {
      $_array_ref->[$_cnt++] = <$_MEM_FILE>;

      while (<$_MEM_FILE>) {
         $_array_ref->[$_cnt  ]  = $_chop_str;
         $_array_ref->[$_cnt++] .= $_;
      }
   }

   close $_MEM_FILE;
   undef $_MEM_FILE;

   return;
}

sub _sync_params {

   my ($self, $_params_ref) = @_;

   die 'Private method called' unless (caller)[0]->isa( ref $self );

   my $_requires_shutdown = 0;

   for (qw( user_begin user_func user_end )) {
      if (defined $_params_ref->{$_}) {
         $self->{$_} = $_params_ref->{$_};
         delete $_params_ref->{$_};
         $_requires_shutdown = 1;
      }
   }

   for (keys %{ $_params_ref }) {
      _croak("MCE::_sync_params: ($_) is not a valid params argument")
         unless (exists $_params_allowed_args{$_});

      $self->{$_} = $_params_ref->{$_};
   }

   return ($self->{_spawned}) ? $_requires_shutdown : 0;
}

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Wrap.
##
###############################################################################

sub _worker_wrap {

   $MCE = $_[0];

   return _worker_main(@_, \@_plugin_worker_init, $_has_threads, $_is_winenv);
}

###############################################################################
## ----------------------------------------------------------------------------
## Dispatch thread.
##
###############################################################################

sub _dispatch_thread {

   my ($self, $_wid, $_task, $_task_id, $_task_wid, $_params) = @_;

   @_ = (); local $_;

   die 'Private method called' unless (caller)[0]->isa( ref $self );

   my $_thr = threads->create( \&_worker_wrap,
      $self, $_wid, $_task, $_task_id, $_task_wid, $_params
   );

   _croak("MCE::_dispatch_thread: Failed to spawn worker $_wid: $!")
      unless (defined $_thr);

   if (defined $_thr) {
      ## Store into an available slot, otherwise append to arrays.
      if (defined $_params) { for (0 .. @{ $self->{_tids} } - 1) {
         unless (defined $self->{_tids}->[$_]) {
            $self->{_thrs}->[$_] = \$_thr;
            $self->{_tids}->[$_] = $_thr->tid();
            return;
         }
      }}

      push @{ $self->{_thrs} }, \$_thr;
      push @{ $self->{_tids} }, $_thr->tid();
   }

   if (defined $self->{spawn_delay} && $self->{spawn_delay} > 0.0) {
      sleep $self->{spawn_delay};
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Dispatch child.
##
###############################################################################

sub _dispatch_child {

   my ($self, $_wid, $_task, $_task_id, $_task_wid, $_params) = @_;

   @_ = (); local $_;

   die 'Private method called' unless (caller)[0]->isa( ref $self );

   my $_pid = fork();

   _croak("MCE::_dispatch_child: Failed to spawn worker $_wid: $!")
      unless (defined $_pid);

   unless ($_pid) {
      _worker_wrap($self, $_wid, $_task, $_task_id, $_task_wid, $_params);

      CORE::kill(9, $$) unless $_is_winenv;
      CORE::exit(0);
   }

   if (defined $_pid) {
      ## Store into an available slot, otherwise append to array.
      if (defined $_params) { for (0 .. @{ $self->{_pids} } - 1) {
         unless (defined $self->{_pids}->[$_]) {
            $self->{_pids}->[$_] = $_pid;
            return;
         }
      }}

      push @{ $self->{_pids} }, $_pid;
   }

   if (defined $self->{spawn_delay} && $self->{spawn_delay} > 0.0) {
      sleep $self->{spawn_delay};
   }

   return;
}

1;

