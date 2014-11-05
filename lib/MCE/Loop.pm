###############################################################################
## ----------------------------------------------------------------------------
## MCE::Loop - Parallel loop model for building creative loops.
##
###############################################################################

package MCE::Loop;

use strict;
use warnings;

use Scalar::Util qw( looks_like_number );

use MCE;
use MCE::Util;

our $VERSION = '1.520'; $VERSION = eval $VERSION;

###############################################################################
## ----------------------------------------------------------------------------
## Import routine.
##
###############################################################################

our $MAX_WORKERS = 'auto';
our $CHUNK_SIZE  = 'auto';

my ($_MCE, $_loaded); my ($_params, $_prev_c); my $_tag = 'MCE::Loop';

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

   *{ $_package . '::mce_loop_f' } = \&mce_loop_f;
   *{ $_package . '::mce_loop_s' } = \&mce_loop_s;
   *{ $_package . '::mce_loop'   } = \&mce_loop;

   return;
}

END {
   return if (defined $_MCE && $_MCE->wid);

   MCE::Loop::finish();
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

   MCE::Loop::finish(); $_params = shift;

   return;
}

sub finish () {

   if (defined $_MCE) {
      MCE::_save_state; $_MCE->shutdown(); MCE::_restore_state;
   }

   $_prev_c = undef;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel loop with MCE -- file.
##
###############################################################################

sub mce_loop_f (&@) {

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

   return mce_loop($_code);
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel loop with MCE -- sequence.
##
###############################################################################

sub mce_loop_s (&@) {

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

   return mce_loop($_code);
}

###############################################################################
## ----------------------------------------------------------------------------
## Parallel loop with MCE.
##
###############################################################################

sub mce_loop (&@) {

   my $_code = shift;

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

      delete $_p->{sequence}   if (defined $_input_data || scalar @_);
      delete $_p->{user_func}  if (exists $_p->{user_func});
      delete $_p->{user_tasks} if (exists $_p->{user_tasks});
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
         max_workers => $_max_workers, task_name => $_tag,
         user_func => $_code
      );

      if (defined $_params) {
         foreach (keys %{ $_params }) {
            next if ($_ eq 'input_data');
            next if ($_ eq 'chunk_size');

            _croak("MCE::Loop: '$_' is not a valid constructor argument")
               unless (exists $MCE::_valid_fields_new{$_});

            $_options{$_} = $_params->{$_};
         }
      }

      $_MCE = MCE->new(%_options);
   }

   ## -------------------------------------------------------------------------

   my @_a; my $_wa = wantarray; $_MCE->{gather} = \@_a if (defined $_wa);

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

   delete $_MCE->{gather} if (defined $_wa);

   MCE::_restore_state;

   return ((defined $_wa) ? @_a : ());
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

MCE::Loop - Parallel loop model for building creative loops

=head1 VERSION

This document describes MCE::Loop version 1.520

=head1 DESCRIPTION

This module provides a parallel loop implementation through Many-core Engine.
MCE::Loop is not MCE::Map but more along the lines of an easy way to spun up a
MCE instance and have user_func pointing to your code block. If you want
something similar to how map works, then also see L<MCE::Map>.

=head1 SYNOPSIS when CHUNK_SIZE EQUALS 1

All models in MCE default to 'auto' for chunk_size. The arguments for the block
are the same as writing a user_func block for the core API.

Beginning with MCE 1.5, the next input item is placed into the input scalar
variable $_ when chunk_size equals 1. Otherwise, $_ points to $chunk_ref
containing many items. Basically, line 2 below may be omitted from your code
when using $_. One can call MCE->chunk_id to obtain the current chunk id.

   line 1:  user_func => sub {
   line 2:     my ($mce, $chunk_ref, $chunk_id) = @_;
   line 3:
   line 4:     $_ points to $chunk_ref->[0]
   line 5:        in MCE 1.5 when chunk_size == 1
   line 6:
   line 7:     $_ points to $chunk_ref
   line 8:        in MCE 1.5 when chunk_size  > 1
   line 9:  }

Follow this synopsis when chunk_size equals one. Looping is not required from
within the block. The block is called once per each item.

   ## Exports mce_loop, mce_loop_f, and mce_loop_s
   use MCE::Loop;

   MCE::Loop::init {
      chunk_size => 1
   };

   ## Array or array_ref
   mce_loop { do_work($_) } 1..10000;
   mce_loop { do_work($_) } [ 1..10000 ];

   ## File_path, glob_ref, or scalar_ref
   mce_loop_f { chomp; do_work($_) } "/path/to/file";
   mce_loop_f { chomp; do_work($_) } $file_handle;
   mce_loop_f { chomp; do_work($_) } \$scalar;

   ## Sequence of numbers (begin, end [, step, format])
   mce_loop_s { do_work($_) } 1, 10000, 5;
   mce_loop_s { do_work($_) } [ 1, 10000, 5 ];

   mce_loop_s { do_work($_) } {
      begin => 1, end => 10000, step => 5, format => undef
   };

=head1 SYNOPSIS when CHUNK_SIZE is GREATER THAN 1

Follow this synopsis when chunk_size equals 'auto' or is greater than 1.
This means having to loop through the chunk from within the block.

   use MCE::Loop;

   MCE::Loop::init {          ## Chunk_size defaults to 'auto' when
      chunk_size => 'auto'    ## not specified. Therefore, the init
   };                         ## function may be omitted.

   ## Syntax is shown for mce_loop for demonstration purposes.
   ## Looping inside the block is the same for mce_loop_f and
   ## mce_loop_s.

   mce_loop { do_work($_) for (@{ $_ }) } 1..10000;

   ## Same as above, resembles code using the core API.

   mce_loop {
      my ($mce, $chunk_ref, $chunk_id) = @_;

      for (@{ $chunk_ref }) {
         do_work($_);
      }

   } 1..10000;

Chunking reduces the number of IPC calls behind the scene. Think in terms of
chunks whenever processing a large amount of data. For relatively small data,
choosing 1 for chunk_size is fine.

=head1 OVERRIDING DEFAULTS

The following list 5 options which may be overridden when loading the module.

   use Sereal qw(encode_sereal decode_sereal);

   use MCE::Loop
         max_workers => 4,                    ## Default 'auto'
         chunk_size  => 100,                  ## Default 'auto'
         tmp_dir     => "/path/to/app/tmp",   ## $MCE::Signal::tmp_dir
         freeze      => \&encode_sereal,      ## \&Storable::freeze
         thaw        => \&decode_sereal       ## \&Storable::thaw
   ;

There is a simpler way to enable Sereal with MCE 1.5. The following will
attempt to use Sereal if available, otherwise will default back to using
Storable for serialization.

   use MCE::Loop Sereal => 1;

   MCE::Loop::init {
      chunk_size => 1
   };

   ## Serialization is through Sereal if available.
   my %answer = mce_loop { MCE->gather( $_, sqrt $_ ) } 1..10000;

=head1 CUSTOMIZING MCE

=over 3

=item init

The init function accepts a hash of MCE options.

   use MCE::Loop;

   MCE::Loop::init {
      chunk_size => 1, max_workers => 4,

      user_begin => sub {
         print "## ", MCE->wid, " started\n";
      },

      user_end => sub {
         print "## ", MCE->wid, " completed\n";
      }
   };

   my %a = mce_loop { MCE->gather($_, $_ * $_) } 1..100;

   print "\n", "@a{1..100}", "\n";

   -- Output

   ## 3 started
   ## 1 started
   ## 2 started
   ## 4 started
   ## 1 completed
   ## 2 completed
   ## 3 completed
   ## 4 completed

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

The following assumes chunk_size equals 1 in order to demonstrate all the
possibilities of passing input data into the loop.

=over 3

=item mce_loop { code } list

Input data can be defined using a list or passing a reference to an array.

   mce_loop { $_ } 1..1000;
   mce_loop { $_ } [ 1..1000 ];

=item mce_loop_f { code } file

The fastest of these is the /path/to/file. Workers communicate the next offset
position among themselves without any interaction from the manager process.

   mce_loop_f { $_ } "/path/to/file";
   mce_loop_f { $_ } $file_handle;
   mce_loop_f { $_ } \$scalar;

=item mce_loop_s { code } sequence

Sequence can be defined as a list, an array reference, or a hash reference.
The functions require both begin and end values to run. Step and format are
optional. The format is passed to sprintf (% may be omitted below).

   my ($beg, $end, $step, $fmt) = (10, 20, 0.1, "%4.1f");

   mce_loop_s { $_ } $beg, $end, $step, $fmt;
   mce_loop_s { $_ } [ $beg, $end, $step, $fmt ];

   mce_loop_s { $_ } {
      begin => $beg, end => $end, step => $step, format => $fmt
   };

=item mce_loop { code } iterator

An iterator reference can by specified for input data. Iterators are described
under "SYNTAX for INPUT_DATA" at L<MCE::Core>.

   mce_loop { $_ } make_iterator(10, 30, 2);

=back

The sequence engine can compute the 'begin' and 'end' items only, for the chunk,
leaving out the items in between with the bounds_only option (boundaries only).
This option applies to sequence and has no effect when chunk_size equals 1.

The time to run for MCE below is 0.006s. This becomes 0.827s without the
bounds_only option due to computing all items in between as well, thus
creating a very large array. Basically, specify bounds_only => 1 when
boundaries is all you need for looping inside the block; e.g Monte Carlo
simulations. Time was measured using 1 worker to emphasize the difference.

   use MCE::Loop;

   MCE::Loop::init {
      max_workers => 1,
    # chunk_size  => 'auto',     ## btw, 'auto' will never drop below 2
      chunk_size  => 1_250_000,
      bounds_only => 1
   };

   ## For sequence, the input scalar $_ points to $chunk_ref
   ## when chunk_size > 1, otherwise equals $chunk_ref->[0].
   ##
   ## mce_loop_s {
   ##    my $begin = $_->[0]; my $end = $_->[-1];
   ##
   ##    for ($begin .. $end) {
   ##       ... have fun with MCE ...
   ##    }
   ##
   ## } 1, 10_000_000;

   mce_loop_s {
      my ($mce, $chunk_ref, $chunk_id) = @_;

      ## $chunk_ref contains just 2 items, not 1_250_000

      my $begin = $chunk_ref->[ 0];
      my $end   = $chunk_ref->[-1];   ## or $chunk_ref->[1]

      MCE->printf("%7d .. %8d\n", $begin, $end);

   } 1, 10_000_000;

   -- Output

         1 ..  1250000
   1250001 ..  2500000
   2500001 ..  3750000
   3750001 ..  5000000
   5000001 ..  6250000
   6250001 ..  7500000
   7500001 ..  8750000
   8750001 .. 10000000

=head1 GATHERING DATA

Unlike MCE::Map where gather and output order are done for you automatically,
the gather method is used to have results sent back to the manager process.

   use MCE::Loop chunk_size => 1;

   ## Output order is not guaranteed.
   my @a = mce_loop { MCE->gather($_ * 2) } 1..100;
   print "@a\n\n";

   ## However, one can store to a hash by gathering 2 items per
   ## each gather call (key, value).
   my %h1 = mce_loop { MCE->gather($_, $_ * 2) } 1..100;
   print "@h1{1..100}\n\n";

   ## This does the same thing due to chunk_id starting at one.
   my %h2 = mce_loop { MCE->gather(MCE->chunk_id, $_ * 2) } 1..100;
   print "@h2{1..100}\n\n";

The gather method can be called multiple times within the block unlike return
which would leave the block. Therefore, think of gather as yielding results
immediately to the manager process without actually leaving the block.

   use MCE::Loop chunk_size => 1, max_workers => 3;

   my @hosts = qw(
      hosta hostb hostc hostd hoste
   );

   my %h3 = mce_loop {
      my ($output, $error, $status); my $host = $_;

      ## Do something with $host;
      $output = "Worker ". MCE->wid .": Hello from $host";

      if (MCE->chunk_id % 3 == 0) {
         ## Simulating an error condition
         local $? = 1; $status = $?;
         $error = "Error from $host"
      }
      else {
         $status = 0;
      }

      ## Ensure unique keys (key, value) when gathering to
      ## a hash.
      MCE->gather("$host.out", $output);
      MCE->gather("$host.err", $error) if (defined $error);
      MCE->gather("$host.sta", $status);

   } @hosts;

   foreach my $host (@hosts) {
      print $h3{"$host.out"}, "\n";
      print $h3{"$host.err"}, "\n" if (exists $h3{"$host.err"});
      print "Exit status: ", $h3{"$host.sta"}, "\n\n";
   }

   -- Output

   Worker 2: Hello from hosta
   Exit status: 0

   Worker 1: Hello from hostb
   Exit status: 0

   Worker 3: Hello from hostc
   Error from hostc
   Exit status: 1

   Worker 2: Hello from hostd
   Exit status: 0

   Worker 1: Hello from hoste
   Exit status: 0

The following uses an anonymous array containing 3 elements when gathering
data. Serialization is automatic behind the scene.

   my %h3 = mce_loop {

      ...

      MCE->gather($host, [$output, $error, $status]);

   } @hosts;

   foreach my $host (@hosts) {
      print $h3{$host}->[0], "\n";
      print $h3{$host}->[1], "\n" if (defined $h3{$host}->[1]);
      print "Exit status: ", $h3{$host}->[2], "\n\n";
   }

Perhaps you want more control with gather such as appending to an array while
retaining output order. Although MCE::Map comes to mind, some folks want "full"
control. And here we go... but this time around in chunking style... :)

The two options passed to MCE::Loop are optional as they default to 'auto'. The
beauty of chunking data is that IPC occurs once per chunk versus once per item.
Although IPC is quite fast, chunking becomes beneficial the larger the data
becomes. Hence, the reason for the demonstration below.

   use MCE::Loop chunk_size => 'auto', max_workers => 'auto';

   my (%_tmp, $_gather_ref, $_order_id);

   sub preserve_order {
      $_tmp{ (shift) } = \@_;

      while (1) {
         last unless exists $_tmp{$_order_id};
         push @{ $_gather_ref }, @{ $_tmp{$_order_id} };
         delete $_tmp{$_order_id++};
      }

      return;
   }

   ## Workers persist after running. Therefore, not recommended to
   ## use a closure for gather unless calling MCE::Loop::init each
   ## time inside the loop. Use this demonstration when wanting
   ## MCE::Loop to maintain output order.

   MCE::Loop::init { gather => \&preserve_order };

   for (1..2) {
      my @m2;

      ## Remember to set $_order_id back to 1 prior to running.
      $_gather_ref = \@m2; $_order_id = 1;

      mce_loop {
         my @a; my ($mce, $chunk_ref, $chunk_id) = @_;

         ## Compute the entire chunk data at once.
         push @a, map { $_ * 2 } @{ $chunk_ref };

         ## Afterwards, invoke the gather feature, which
         ## will direct the data to the callback function.
         MCE->gather(MCE->chunk_id, @a);

      } 1..100000;

      print scalar @m2, "\n";
   }

All 6 models support 'auto' for chunk_size whereas the core API doesn't. Think
of the models as the basis for providing JIT for MCE. They create the instance
and tune max_workers plus chunk_size automatically irregardless of the
hardware being run on.

The following does the same thing using the core API.

   use MCE;

   ...

   my $mce = MCE->new(
      max_workers => 'auto', chunk_size => 8000,
      gather => \&preserve_order,

      user_func => sub {
         my @a; my ($mce, $chunk_ref, $chunk_id) = @_;

         ## Compute the entire chunk data at once.
         push @a, map { $_ * 2 } @{ $chunk_ref };

         ## Afterwards, invoke the gather feature, which
         ## will direct the data to the callback function.
         MCE->gather(MCE->chunk_id, @a);
      }
   );

   $mce->process([1..100000]);

   ...

=head1 MANUAL SHUTDOWN

=over 3

=item finish

MCE workers remain persistent as much as possible after running. Shutdown
occurs when the script exits. One can manually shutdown MCE by simply calling
finish after running. This resets the MCE instance.

   use MCE::Loop;

   MCE::Loop::init {
      chunk_size => 20, max_workers => 'auto'
   };

   mce_loop { ... } 1..100;

   MCE::Loop::finish;

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

