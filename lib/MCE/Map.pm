###############################################################################
## ----------------------------------------------------------------------------
## MCE::Map - Parallel map model similar to the native map function.
##
###############################################################################

package MCE::Map;

use strict;
use warnings;

use Scalar::Util qw( looks_like_number );

use MCE;
use MCE::Util;

our $VERSION = '1.515'; $VERSION = eval $VERSION;

###############################################################################
## ----------------------------------------------------------------------------
## Import routine.
##
###############################################################################

our $MAX_WORKERS = 'auto';
our $CHUNK_SIZE  = 'auto';

my ($_MCE, $_loaded); my ($_params, $_prev_c); my $_tag = 'MCE::Map';

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

   *{ $_package . '::mce_map_f' } = \&mce_map_f;
   *{ $_package . '::mce_map_s' } = \&mce_map_s;
   *{ $_package . '::mce_map'   } = \&mce_map;

   return;
}

END {
   return if (defined $_MCE && $_MCE->wid);

   MCE::Map::finish();
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

   MCE::Map::finish(); $_params = shift;

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
## Parallel map with MCE -- file.
##
###############################################################################

sub mce_map_f (&@) {

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

   return mce_map($_code);
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel map with MCE -- sequence.
##
###############################################################################

sub mce_map_s (&@) {

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

   return mce_map($_code);
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel map with MCE.
##
###############################################################################

sub mce_map (&@) {

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
                  while ( <$_MEM_FH> ) { push @_a, &$_code; }
                  close    $_MEM_FH;
               }
               else {
                  if (ref $_chunk_ref) {
                     push @_a, map { &$_code } @$_chunk_ref;
                  } else {
                     push @_a, map { &$_code } $_chunk_ref;
                  }
               }

               MCE->gather(\@_a, $_chunk_id);
            }
            else {
               my $_cnt = 0;

               if (ref $_chunk_ref eq 'SCALAR') {
                  local $/ = $_mce->{RS} if defined $_mce->{RS};
                  open my  $_MEM_FH, '<', $_chunk_ref;
                  while ( <$_MEM_FH> ) { $_cnt++; &$_code; }
                  close    $_MEM_FH;
               }
               else {
                  if (ref $_chunk_ref) {
                     $_cnt += map { &$_code } @$_chunk_ref;
                  } else {
                     $_cnt += map { &$_code } $_chunk_ref;
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

            _croak("MCE::Map: '$_' is not a valid constructor argument")
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

MCE::Map - Parallel map model similar to the native map function

=head1 VERSION

This document describes MCE::Map version 1.515

=head1 SYNOPSIS

   ## Exports mce_map, mce_map_f, and mce_map_s
   use MCE::Map;

   ## Array or array_ref
   my @a = mce_map { $_ * $_ } 1..10000;
   my @b = mce_map { $_ * $_ } [ 1..10000 ];

   ## File_path, glob_ref, or scalar_ref
   my @c = mce_map_f { chomp; $_ } "/path/to/file";
   my @d = mce_map_f { chomp; $_ } $file_handle;
   my @e = mce_map_f { chomp; $_ } \$scalar;

   ## Sequence of numbers (begin, end [, step, format])
   my @f = mce_map_s { $_ * $_ } 1, 10000, 5;
   my @g = mce_map_s { $_ * $_ } [ 1, 10000, 5 ];

   my @h = mce_map_s { $_ * $_ } {
      begin => 1, end => 10000, step => 5, format => undef
   };

=head1 DESCRIPTION

This module provides a parallel map implementation via Many-core Engine. MCE
incurs a small overhead due to passing of data. Therefore, a fast code block
will likely run faster using the native map function in Perl. The overhead
quickly diminishes as the complexity of the code block increases.

   my @m1 =     map { $_ * $_ } 1..1000000;               ## 0.251 secs
   my @m2 = mce_map { $_ * $_ } 1..1000000;               ## 0.525 secs

Chunking, enabled by default, greatly reduces the overhead behind the scene.
The time for mce_map below also includes the time for data exchanges between
the manager and worker processes. More parallelization will be seen when the
code block requires additional CPU time code-wise.

   sub calc {
      sqrt $_ * sqrt $_ / 1.3 * 1.5 / 3.2 * 1.07
   }

   my @m1 =     map { calc } 1..1000000;                  ## 0.756 secs
   my @m2 = mce_map { calc } 1..1000000;                  ## 0.623 secs

The mce_map_s function will provide better times, useful when the input data
is simply a range of numbers. Workers generate sequences mathematically among
themselves without any interaction from the manager process. Two arguments are
required for mce_map_s (begin, end). Step defaults to 1 if begin is smaller
than end, otherwise -1.

   my @m3 = mce_map_s { calc } 1, 1000000;                ## 0.517 secs

Although this document is about MCE::Map, the L<MCE::Stream> module can write
results immediately without waiting for all chunks to complete. This is made
possible by passing the reference of the array (in this case @m4 and @m5).

   use MCE::Stream;

   sub calc {
      sqrt $_ * sqrt $_ / 1.3 * 1.5 / 3.2 * 1.07
   }

   my @m4; mce_stream \@m4, sub { calc }, 1..1000000;

      ## Completes in 0.436 secs. That is amazing considering the
      ## overhead for passing data between the manager and worker.

   my @m5; mce_stream_s \@m5, sub { calc }, 1, 1000000;

      ## Completed in 0.301 secs. Like with mce_map_s, specifying a
      ## sequence specification turns out to be faster due to lesser
      ## overhead for the manager process.

=head1 OVERRIDING DEFAULTS

The following list 5 options which may be overridden when loading the module.

   use Sereal qw(encode_sereal decode_sereal);

   use MCE::Map
         max_workers => 4,                    ## Default 'auto'
         chunk_size  => 100,                  ## Default 'auto'
         tmp_dir     => "/path/to/app/tmp",   ## $MCE::Signal::tmp_dir
         freeze      => \&encode_sereal,      ## \&Storable::freeze
         thaw        => \&decode_sereal       ## \&Storable::thaw
   ;

There is a simpler way to enable Sereal with MCE 1.5. The following will
attempt to use Sereal if available, otherwise will default back to using
Storable for serialization.

   use MCE::Map Sereal => 1;

   ## Serialization is through Sereal if available.
   my @m2 = mce_map { $_ * $_ } 1..10000;

=head1 CUSTOMIZING MCE

=over 3

=item init

The init function accepts a hash of MCE options. The gather option, if
specified, will be set to undef due to being used internally by the module.

   use MCE::Map;

   MCE::Map::init {
      chunk_size => 1, max_workers => 4,

      user_begin => sub {
         print "## ", MCE->wid, " started\n";
      },

      user_end => sub {
         print "## ", MCE->wid, " completed\n";
      }
   };

   my @a = mce_map { $_ * $_ } 1..100;

   print "\n", "@a", "\n";

   -- Output

   ## 2 started
   ## 1 started
   ## 3 started
   ## 4 started
   ## 1 completed
   ## 4 completed
   ## 2 completed
   ## 3 completed

   1 4 9 16 25 36 49 64 81 100 121 144 169 196 225 256 289 324 361
   400 441 484 529 576 625 676 729 784 841 900 961 1024 1089 1156
   1225 1296 1369 1444 1521 1600 1681 1764 1849 1936 2025 2116 2209
   2304 2401 2500 2601 2704 2809 2916 3025 3136 3249 3364 3481 3600
   3721 3844 3969 4096 4225 4356 4489 4624 4761 4900 5041 5184 5329
   5476 5625 5776 5929 6084 6241 6400 6561 6724 6889 7056 7225 7396
   7569 7744 7921 8100 8281 8464 8649 8836 9025 9216 9409 9604 9801
   10000

=back

=head1 API DOCUMENTATION

=over 3

=item mce_map { code } list

Input data can be defined using a list or passing a reference to an array.

   my @a = mce_map { $_ * 2 } 1..1000;
   my @b = mce_map { $_ * 2 } [ 1..1000 ];

=item mce_map_f { code } file

The fastest of these is the /path/to/file. Workers communicate the next offset
position among themselves without any interaction from the manager process.

   my @c = mce_map_f { chomp; $_ . "\r\n" } "/path/to/file";
   my @d = mce_map_f { chomp; $_ . "\r\n" } $file_handle;
   my @e = mce_map_f { chomp; $_ . "\r\n" } \$scalar;

=item mce_map_s { code } sequence

Sequence can be defined as a list, an array reference, or a hash reference.
The functions require both begin and end values to run. Step and format are
optional. The format is passed to sprintf (% may be omitted below).

   my ($beg, $end, $step, $fmt) = (10, 20, 0.1, "%4.1f");

   my @f = mce_map_s { $_ } $beg, $end, $step, $fmt;
   my @g = mce_map_s { $_ } [ $beg, $end, $step, $fmt ];

   my @h = mce_map_s { $_ } {
      begin => $beg, end => $end, step => $step, format => $fmt
   };

=item mce_map { code } iterator

An iterator reference can by specified for input data. Iterators are described
under "SYNTAX for INPUT_DATA" at L<MCE::Core>.

   my @a = mce_map { $_ * 2 } make_iterator(10, 30, 2);

=back

=head1 MANUAL SHUTDOWN

=over 3

=item finish

MCE workers remain persistent as much as possible after running. Shutdown
occurs when the script exits. One can manually shutdown MCE by simply calling
finish after running. This resets the MCE instance.

   use MCE::Map;

   MCE::Map::init {
      chunk_size => 20, max_workers => 'auto'
   };

   my @a = mce_map { ... } 1..100;

   MCE::Map::finish;

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

