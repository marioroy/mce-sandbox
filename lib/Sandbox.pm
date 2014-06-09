
package Sandbox;

use strict;
use warnings;

our $VERSION = '1.000';

## use bigint;

use Scalar::Util qw(looks_like_number);
use Fcntl qw(O_RDONLY);

use constant {
   MODE_COUNT => 1,
   MODE_PRINT => 2,
   MODE_SUM   => 3
};

sub import {
   no strict 'refs'; no warnings 'redefine';
   my $pkg = caller();
   *{ $pkg . '::MODE_COUNT' } = \&MODE_COUNT;
   *{ $pkg . '::MODE_PRINT' } = \&MODE_PRINT;
   *{ $pkg . '::MODE_SUM'   } = \&MODE_SUM;
   return;
}

sub min {
   return $_[ ($_[0] + 0 > $_[1] + 0) ];
}

our $N_agg = 0;

###############################################################################
## ----------------------------------------------------------------------------
## Check numbers.
##
###############################################################################

sub check_numbers
{
   my ($prog_name, $max_number, $F_arg, $N_arg, $sum_flag) = @_;

   local $@; no warnings;

   die "$prog_name: number must be an integer greater than 0.\n"
      unless defined $F_arg && defined $N_arg;

   die "$prog_name: 1st number must be an integer greater than 0.\n"
      unless looks_like_number($F_arg) &&
         $F_arg > 0 && int($F_arg) == $F_arg;

   die "$prog_name: 2nd number must be an integer greater than $F_arg.\n"
      unless looks_like_number($N_arg) &&
         $N_arg >= $F_arg && int($N_arg) == $N_arg;

   die "$prog_name: sum: number 29505444490 is the maximum allowed.\n"
      if $sum_flag && $N_arg > 29505444490;

   die "$prog_name: number $max_number is the maximum allowed.\n"
      if min($max_number, $N_arg) ne $N_arg;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Callback functions for MCE.
##
###############################################################################

sub i_iter
{
   my ($F, $N, $step_size) = @_;
   my $n_seq;

   return sub {
      return $n_seq = $F if (not $n_seq);
      return if ($n_seq + $step_size > $N);
      return $n_seq += $step_size;
   }
}

sub o_iter
{
   my ($F, $N, $step_size, $quiet_flag, $run_mode) = @_;

   my ($completed, $inc, $progress) = (1, 1.0, 0.0);
   my $factor = int(($N - $F) / $step_size) + 1;
   my $show_progress = $quiet_flag ? 0 : 1;

   if ($factor >= 100) {
      $factor = int(($factor - 1) / 100) + 1;
   } else {
      $inc = 100 / $factor;
   }

   my (%cache, $file, $fh, $n_read, $buf, $order_id);

   if ($run_mode == MODE_PRINT) {
      $buf = sprintf("%49152s", "");
      keys(%cache) = 256;
      $order_id = 1;
   }

   return sub {

      syswrite(\*STDERR, "  " . int($progress += $inc) . "%\r")
         if ($show_progress && ++$completed % $factor == 0);

      if ($run_mode != MODE_PRINT) {
         $N_agg += $_[0];
         return;
      }

      $cache{$_[0]} = 1;

      while (exists $cache{$order_id}) {
         $file = MCE->tmp_dir() . "/$order_id";

         if (-s $file) {
            $N_agg = 1;
            sysopen($fh, $file, O_RDONLY);
            syswrite(\*STDERR, "      \r") if $order_id == 1;

            while (1) {
               $n_read = sysread($fh, $buf, 49152);
               last if $n_read == 0;

               syswrite(\*STDOUT, $buf, $n_read);
            }

            close($fh);
         }

         unlink $file;
         delete $cache{$order_id++};
      }

      return;
   };
}

###############################################################################
## ----------------------------------------------------------------------------
## The end.
##
###############################################################################

sub end
{
   my ($quiet_flag, $run_mode, $lapse) = @_;

   if ($quiet_flag) {
      print $N_agg, "\n" if $run_mode != MODE_PRINT;
   }
   else {
      if ($lapse > 0.125) {
         syswrite(\*STDERR, "  100%\r");
         sleep(0.07);
      }
      syswrite(\*STDERR, "      \r");

      print  STDERR "Prime numbers : ", $N_agg, "\n" if $run_mode == MODE_COUNT;
      print  STDERR "Sum of primes : ", $N_agg, "\n" if $run_mode == MODE_SUM;
      printf STDERR "Compute time  : %0.03f sec\n", $lapse;
   }

   return ($N_agg > 0) ? 0 : 1;
}

1;

