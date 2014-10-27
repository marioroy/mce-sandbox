###############################################################################
## ----------------------------------------------------------------------------
## MCE::Grep - Parallel grep model similar to the native grep function.
##
###############################################################################

package MCE::Grep;

use strict;
use warnings;

use Scalar::Util qw( looks_like_number );

use MCE;
use MCE::Util;

our $VERSION = '1.518'; $VERSION = eval $VERSION;

###############################################################################
## ----------------------------------------------------------------------------
## Import routine.
##
###############################################################################

our $MAX_WORKERS = 'auto';
our $CHUNK_SIZE  = 'auto';

my ($_MCE, $_loaded); my ($_params, $_prev_c); my $_tag = 'MCE::Grep';

sub import {

   my $_class = shift; return if ($_loaded++);

   ## Process module arguments.
   while (my $_arg = shift) {

      $MAX_WORKERS  = shift and next if ( $_arg =~ /^max_workers$/i );
      $CHUNK_SIZE   = shift and next if ( $_arg =~ /^chunk_size$/i );
      $MCE::TMP_DIR = shift and next if ( $_arg =~ /^tmp_dir$/i );
      $MCE::FREEZE  = shift and next if ( $_arg =~ /^freeze$/i );
      $MCE::THAW    = shift and next if ( $_arg =~ /^thaw$/i );

      if ( $_arg =~ /^sereal$/i ) {
         if (shift eq '1') {
            local $@; eval 'use Sereal qw(encode_sereal decode_sereal)';
            unless ($@) {
               $MCE::FREEZE = \&encode_sereal;
               $MCE::THAW   = \&decode_sereal;
            }
         }
         next;
      }

      _croak("$_tag::import: '$_arg' is not a valid module argument");
   }

   $MAX_WORKERS = MCE::Util::_parse_max_workers($MAX_WORKERS);
   _validate_number($MAX_WORKERS, 'MAX_WORKERS');

   _validate_number($CHUNK_SIZE, 'CHUNK_SIZE')
      unless ($CHUNK_SIZE eq 'auto');

   ## Import functions.
   no strict 'refs'; no warnings 'redefine';
   my $_package = caller();

   *{ $_package . '::mce_grep_f' } = \&mce_grep_f;
   *{ $_package . '::mce_grep_s' } = \&mce_grep_s;
   *{ $_package . '::mce_grep'   } = \&mce_grep;

   return;
}

END {
   return if (defined $_MCE && $_MCE->wid);

   MCE::Grep::finish();
}

###############################################################################
## ----------------------------------------------------------------------------
## Gather callback for storing by chunk_id => chunk_ref into a hash.
##
###############################################################################

my ($_total_chunks, %_tmp);

sub _gather {

   $_tmp{$_[1]} = $_[0];
   $_total_chunks++;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Init and finish routines.
##
###############################################################################

sub init (@) {

   if (MCE->wid) {
      @_ = (); _croak(
         "$_tag: function cannot be called by the worker process"
      );
   }

   _croak("$_tag: 'argument' is not a HASH reference")
      unless (ref $_[0] eq 'HASH');

   MCE::Grep::finish(); $_params = shift;

   return;
}

sub finish () {

   if (defined $_MCE) {
      MCE::_save_state; $_MCE->shutdown(); MCE::_restore_state;
   }

   $_prev_c = $_total_chunks = undef; undef %_tmp;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel grep with MCE -- file.
##
###############################################################################

sub mce_grep_f (&@) {

   my $_code = shift; my $_file = shift;

   if (defined $_params) {
      delete $_params->{input_data} if (exists $_params->{input_data});
      delete $_params->{sequence}   if (exists $_params->{sequence});
   }
   else {
      $_params = {};
   }

   if (defined $_file && ref $_file eq "" && $_file ne "") {
      _croak("$_tag: '$_file' does not exist") unless (-e $_file);
      _croak("$_tag: '$_file' is not readable") unless (-r $_file);
      _croak("$_tag: '$_file' is not a plain file") unless (-f $_file);
      $_params->{_file} = $_file;
   }
   elsif (ref $_file eq 'GLOB' || ref $_file eq 'SCALAR' || ref($_file) =~ /^IO::/) {
      $_params->{_file} = $_file;
   }
   else {
      _croak("$_tag: 'file' is not specified or valid");
   }

   @_ = ();

   return mce_grep($_code);
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel grep with MCE -- sequence.
##
###############################################################################

sub mce_grep_s (&@) {

   my $_code = shift;

   if (defined $_params) {
      delete $_params->{input_data} if (exists $_params->{input_data});
      delete $_params->{_file}      if (exists $_params->{_file});
   }
   else {
      $_params = {};
   }

   my ($_begin, $_end);

   if (ref $_[0] eq 'HASH') {
      $_begin = $_[0]->{begin}; $_end = $_[0]->{end};
      $_params->{sequence} = $_[0];
   }
   elsif (ref $_[0] eq 'ARRAY') {
      $_begin = $_[0]->[0]; $_end = $_[0]->[1];
      $_params->{sequence} = $_[0];
   }
   elsif (ref $_[0] eq "") {
      $_begin = $_[0]; $_end = $_[1];
      $_params->{sequence} = [ @_ ];
   }
   else {
      _croak("$_tag: 'sequence' is not specified or valid");
   }

   _croak("$_tag: 'begin' is not specified for sequence")
      unless (defined $_begin);

   _croak("$_tag: 'end' is not specified for sequence")
      unless (defined $_end);

   @_ = ();

   return mce_grep($_code);
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel grep with MCE.
##
###############################################################################

sub mce_grep (&@) {

   my $_code = shift;   $_total_chunks = 0; undef %_tmp;

   if (MCE->wid) {
      @_ = (); _croak(
         "$_tag: function cannot be called by the worker process"
      );
   }

   my $_input_data; my $_max_workers = $MAX_WORKERS; my $_r = ref $_[0];

   if ($_r eq 'ARRAY' || $_r eq 'CODE' || $_r eq 'GLOB' || $_r eq 'SCALAR' || $_r =~ /^IO::/) {
      $_input_data = shift;
   }

   if (defined $_params) { my $_p = $_params;
      $_max_workers = MCE::Util::_parse_max_workers($_p->{max_workers})
         if (exists $_p->{max_workers});

      delete $_p->{sequence}    if (defined $_input_data || scalar @_);
      delete $_p->{user_func}   if (exists $_p->{user_func});
      delete $_p->{user_tasks}  if (exists $_p->{user_tasks});
      delete $_p->{use_slurpio} if (exists $_p->{use_slurpio});
      delete $_p->{bounds_only} if (exists $_p->{bounds_only});
      delete $_p->{gather}      if (exists $_p->{gather});
   }

   my $_chunk_size = MCE::Util::_parse_chunk_size(
      $CHUNK_SIZE, $_max_workers, $_params, $_input_data, scalar @_
   );

   if (defined $_params) {
      $_input_data = $_params->{input_data} if (exists $_params->{input_data});

      if (exists $_params->{_file}) {
         $_input_data = $_params->{_file}; delete $_params->{_file};
      }
   }

   MCE::_save_state;

   ## -------------------------------------------------------------------------

   if (!defined $_prev_c || $_prev_c != $_code) {
      $_MCE->shutdown() if (defined $_MCE);
      $_prev_c = $_code;

      my %_options = (
         use_threads => 0, max_workers => $_max_workers, task_name => $_tag,
         user_func => sub {

            my ($_mce, $_chunk_ref, $_chunk_id) = @_;
            my $_wantarray = $_mce->{user_args}[0];

            if ($_wantarray) {
               my @_a;

               if (ref $_chunk_ref eq 'SCALAR') {
                  local $/ = $_mce->{RS} if defined $_mce->{RS};
                  open my  $_MEM_FH, '<', $_chunk_ref;
                  while ( <$_MEM_FH> ) { push (@_a, $_) if &$_code; }
                  close    $_MEM_FH;
               }
               else {
                  if (ref $_chunk_ref) {
                     push @_a, grep { &$_code } @$_chunk_ref;
                  } else {
                     push @_a, grep { &$_code } $_chunk_ref;
                  }
               }

               MCE->gather(\@_a, $_chunk_id);
            }
            else {
               my $_cnt = 0;

               if (ref $_chunk_ref eq 'SCALAR') {
                  local $/ = $_mce->{RS} if defined $_mce->{RS};
                  open my  $_MEM_FH, '<', $_chunk_ref;
                  while ( <$_MEM_FH> ) { $_cnt++ if &$_code; }
                  close    $_MEM_FH;
               }
               else {
                  if (ref $_chunk_ref) {
                     $_cnt += grep { &$_code } @$_chunk_ref;
                  } else {
                     $_cnt += grep { &$_code } $_chunk_ref;
                  }
               }

               MCE->gather($_cnt) if defined $_wantarray;
            }
         }
      );

      if (defined $_params) {
         foreach (keys %{ $_params }) {
            next if ($_ eq 'input_data');
            next if ($_ eq 'chunk_size');

            _croak("MCE::Grep: '$_' is not a valid constructor argument")
               unless (exists $MCE::_valid_fields_new{$_});

            $_options{$_} = $_params->{$_};
         }
      }

      $_MCE = MCE->new(%_options);
   }

   ## -------------------------------------------------------------------------

   my $_cnt = 0; my $_wantarray = wantarray;

   $_MCE->{use_slurpio} = ($_chunk_size > MCE::MAX_RECS_SIZE) ? 1 : 0;
   $_MCE->{user_args} = [ $_wantarray ];

   $_MCE->{gather} = $_wantarray
      ? \&_gather : sub { $_cnt += $_[0]; return; };

   if (defined $_input_data) {
      @_ = (); $_MCE->process({ chunk_size => $_chunk_size }, $_input_data);
   }
   elsif (scalar @_) {
      $_MCE->process({ chunk_size => $_chunk_size }, \@_);
   }
   else {
      $_MCE->run({ chunk_size => $_chunk_size }, 0)
         if (defined $_params && exists $_params->{sequence});
   }

   MCE::_restore_state;

   if ($_wantarray) {
      return map { @{ $_ } } delete @_tmp{ 1 .. $_total_chunks };
   }
   elsif (defined $_wantarray) {
      return $_cnt;
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods.
##
###############################################################################

sub _croak {

   goto &MCE::_croak;
}

sub _validate_number {

   my $_n = $_[0]; my $_key = $_[1];

   $_n =~ s/K\z//i; $_n =~ s/M\z//i;

   _croak("$_tag: '$_key' is not valid")
      if (!looks_like_number($_n) || int($_n) != $_n || $_n < 1);

   return;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Grep - Parallel grep model similar to the native grep function

=head1 VERSION

This document describes MCE::Grep version 1.518

=head1 SYNOPSIS

   ## Exports mce_grep, mce_grep_f, and mce_grep_s
   use MCE::Grep;

   ## Array or array_ref
   my @a = mce_grep { $_ % 5 == 0 } 1..10000;
   my @b = mce_grep { $_ % 5 == 0 } [ 1..10000 ];

   ## File_path, glob_ref, or scalar_ref
   my @c = mce_grep_f { /phrase/ } "/path/to/file";
   my @d = mce_grep_f { /phrase/ } $file_handle;
   my @e = mce_grep_f { /phrase/ } \$scalar;

   ## Sequence of numbers (begin, end [, step, format])
   my @f = mce_grep_s { %_ * 3 == 0 } 1, 10000, 5;
   my @g = mce_grep_s { %_ * 3 == 0 } [ 1, 10000, 5 ];

   my @h = mce_grep_s { %_ * 3 == 0 } {
      begin => 1, end => 10000, step => 5, format => undef
   };

=head1 DESCRIPTION

This module provides a parallel grep implementation via Many-core Engine. MCE
incurs a small overhead due to passing of data. Therefore, a fast code block
will likely run faster using the native grep function in Perl. The overhead
quickly diminishes as the complexity of the code block increases.

   my @m1 =     grep { $_ % 5 == 0 } 1..1000000;          ## 0.137 secs
   my @m2 = mce_grep { $_ % 5 == 0 } 1..1000000;          ## 0.295 secs

Chunking, enabled by default, greatly reduces the overhead behind the scene.
The time for mce_grep below also includes the time for data exchanges between
the manager and worker processes. More parallelization will be seen when the
code block requires additional CPU time code-wise.

   my @m1 =     grep { /[2357][1468][9]/ } 1..1000000;    ## 0.653 secs
   my @m2 = mce_grep { /[2357][1468][9]/ } 1..1000000;    ## 0.347 secs

The mce_grep_s function will provide better times, useful when the input data
is simply a range of numbers. Workers generate sequences mathematically among
themselves without any interaction from the manager process. Two arguments are
required for mce_grep_s (begin, end). Step defaults to 1 if begin is smaller
than end, otherwise -1.

   my @m3 = mce_grep_s { /[2357][1468][9]/ } 1, 1000000;  ## 0.271 secs

Although this document is about MCE::Grep, the L<MCE::Stream> module can write
results immediately without waiting for all chunks to complete. This is made
possible by passing the reference of the array (in this case @m4 and @m5).

   use MCE::Stream default_mode => 'grep';

   my @m4; mce_stream \@m4, sub { /[2357][1468][9]/ }, 1..1000000;

      ## Completed in 0.304 secs. That is amazing considering the
      ## overhead for passing data between the manager and worker.

   my @m5; mce_stream_s \@m5, sub { /[2357][1468][9]/ }, 1, 1000000;

      ## Completed in 0.227 secs. Like with mce_grep_s, specifying a
      ## sequence specification turns out to be faster due to lesser
      ## overhead for the manager process.

A good use-case for MCE::Grep is for searching through a large log file much
like one might do using the native grep function. Lets assume the file contains
a hundred thousand records separated by a string "::\n\n" between each record.
The imaginary pattern used also returns less than 50 records.

The native implementation is what one might do actually. What's not clearly
visible here is the initial memory consumption, due to Perl reading the entire
content into memory, prior to grep actually starting. A 300 MB file will
consume roughly 640 MB. The time to run is 1.217 seconds for the file
residing in the OS-level file-system cache.

   $/ = "::\n\n";

   open my $LOG, "<", "/path/to/log/file";
   my @match = grep { $_ =~ /pattern/ } <$LOG>;
   close $LOG;

The memory utilization is much better with MCE; 8 workers * 23 MB = 184 MB.
MCE caps at some point, therefore allowing one to process a file much larger
than available memory. The time to run is 0.416 seconds (2.93x faster) which
includes the overhead for chunking and serializing data back to the main
process as if processing serially.

   use MCE::Grep;

   MCE::Grep::init { RS => "::\n\n" };

   my @match = mce_grep_f { $_ =~ /pattern/ } "/path/to/file";

It gets even better for counting though. The native grep function takes 1.136
seconds to run whereas MCE takes just 0.155 seconds (7.33x faster).

   ## Native Grep
   my $count = grep { $_ =~ /pattern/ } <$LOG>;

   ## MCE Grep
   my $count = mce_grep_f { $_ =~ /pattern/ } "/path/to/file";

=head1 OVERRIDING DEFAULTS

The following list 5 options which may be overridden when loading the module.

   use Sereal qw(encode_sereal decode_sereal);

   use MCE::Grep
         max_workers => 4,                    ## Default 'auto' 
         chunk_size  => 100,                  ## Default 'auto'
         tmp_dir     => "/path/to/app/tmp",   ## $MCE::Signal::tmp_dir
         freeze      => \&encode_sereal,      ## \&Storable::freeze
         thaw        => \&decode_sereal       ## \&Storable::thaw
   ;

There is a simpler way to enable Sereal with MCE 1.5. The following will
attempt to use Sereal if available, otherwise will default back to using
Storable for serialization.

   use MCE::Grep Sereal => 1;

   ## Serialization is through Sereal if available.
   my @m2 = mce_grep { $_ % 5 == 0 } 1..10000;

=head1 CUSTOMIZING MCE

=over 3

=item init

The init function accepts a hash of MCE options. The gather option, if
specified, will be set to undef due to being used internally by the module.

   use MCE::Grep;

   MCE::Grep::init {
      chunk_size => 1, max_workers => 4,

      user_begin => sub {
         print "## ", MCE->wid, " started\n";
      },

      user_end => sub {
         print "## ", MCE->wid, " completed\n";
      }
   };

   my @a = mce_grep { $_ % 5 == 0 } 1..100;

   print "\n", "@a", "\n";

   -- Output

   ## 2 started
   ## 3 started
   ## 1 started
   ## 4 started
   ## 3 completed
   ## 4 completed
   ## 1 completed
   ## 2 completed

   5 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100

=back

=head1 API DOCUMENTATION

=over 3

=item mce_grep { code } list

Input data can be defined using a list or passing a reference to an array.

   my @a = mce_grep { /[2357]/ } 1..1000;
   my @b = mce_grep { /[2357]/ } [ 1..1000 ];

=item mce_grep_f { code } file

The fastest of these is the /path/to/file. Workers communicate the next offset
position among themselves without any interaction from the manager process.

   my @c = mce_grep_f { /phrase/ } "/path/to/file";
   my @d = mce_grep_f { /phrase/ } $file_handle;
   my @e = mce_grep_f { /phrase/ } \$scalar;

=item mce_grep_s { code } sequence

Sequence can be defined as a list, an array reference, or a hash reference.
The functions require both begin and end values to run. Step and format are
optional. The format is passed to sprintf (% may be omitted below).

   my ($beg, $end, $step, $fmt) = (10, 20, 0.1, "%4.1f");

   my @f = mce_grep_s { /[1234]\.[5678]/ } $beg, $end, $step, $fmt;
   my @g = mce_grep_s { /[1234]\.[5678]/ } [ $beg, $end, $step, $fmt ];

   my @h = mce_grep_s { /[1234]\.[5678]/ } {
      begin => $beg, end => $end, step => $step, format => $fmt
   };

=item mce_grep { code } iterator

An iterator reference can by specified for input data. Iterators are described
under "SYNTAX for INPUT_DATA" at L<MCE::Core>.

   my @a = mce_grep { $_ % 3 == 0 } make_iterator(10, 30, 2);

=back

=head1 MANUAL SHUTDOWN

=over 3

=item finish

MCE workers remain persistent as much as possible after running. Shutdown
occurs when the script exits. One can manually shutdown MCE by simply calling
finish after running. This resets the MCE instance.

   use MCE::Grep;

   MCE::Grep::init {
      chunk_size => 20, max_workers => 'auto'
   };

   my @a = mce_grep { ... } 1..100;

   MCE::Grep::finish;

=back

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

