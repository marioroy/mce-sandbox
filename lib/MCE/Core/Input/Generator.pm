###############################################################################
## ----------------------------------------------------------------------------
## MCE::Core::Input::Generator - Sequence of numbers (for task_id > 0).
##
## This package provides a sequence of numbers used internally by the worker
## process. Distribution is divided equally among workers. This allows sequence
## to be configured independently among multiple user tasks.
##
## There is no public API.
##
###############################################################################

package MCE::Core::Input::Generator;

our $VERSION = '1.519'; $VERSION = eval $VERSION;

## Items below are folded into MCE.

package MCE;

use strict;
use warnings;

## Warnings are disabled to minimize bits of noise when user or OS signals
## the script to exit. e.g. MCE_script.pl < infile | head

no warnings 'threads'; no warnings 'uninitialized';

###############################################################################
## ----------------------------------------------------------------------------
## Worker process -- Sequence Generator (equal distribution among workers).
##
###############################################################################

sub _worker_sequence_generator {

   my MCE $self = $_[0];

   @_ = ();

   die "Private method called" unless (caller)[0]->isa( ref($self) );

   _croak("MCE::_worker_sequence_generator: 'user_func' is not specified")
      unless (defined $self->{user_func});

   my $_bounds_only = $self->{bounds_only} || 0;
   my $_max_workers = $self->{max_workers};
   my $_chunk_size  = $self->{chunk_size};
   my $_wuf         = $self->{_wuf};

   my ($_begin, $_end, $_step, $_fmt);

   if (ref $self->{sequence} eq 'ARRAY') {
      ($_begin, $_end, $_step, $_fmt) = @{ $self->{sequence} };
   }
   else {
      $_begin = $self->{sequence}->{begin};
      $_end   = $self->{sequence}->{end};
      $_step  = $self->{sequence}->{step};
      $_fmt   = $self->{sequence}->{format};
   }

   my $_wid      = $self->{_task_wid} || $self->{_wid};
   my $_next     = ($_wid - 1) * $_chunk_size * $_step + $_begin;
   my $_chunk_id = $_wid;

   $_fmt =~ s/%// if (defined $_fmt);

   ## -------------------------------------------------------------------------

   $self->{_last_jmp} = sub { goto _WORKER_SEQ_GEN__LAST; };

   if ($_begin == $_end) {                        ## Identical, yes.

      if ($_wid == 1) {
         $self->{_next_jmp} = sub { goto _WORKER_SEQ_GEN__LAST; };

         local $_ = (defined $_fmt) ? sprintf("%$_fmt", $_next) : $_next;

         if ($_chunk_size > 1) {
            $_ = ($_bounds_only) ? [ $_, $_ ] : [ $_ ];
         }

         $_wuf->($self, $_, $_chunk_id);
      }
   }
   elsif ($_chunk_size == 1) {                    ## Chunking, no.

      $self->{_next_jmp} = sub { goto _WORKER_SEQ_GEN__NEXT_A; };

      my $_flag = ($_begin < $_end);

      while (1) {
         return if ( $_flag && $_next > $_end);
         return if (!$_flag && $_next < $_end);

         local $_ = (defined $_fmt) ? sprintf("%$_fmt", $_next) : $_next;
         $_wuf->($self, $_, $_chunk_id);

         _WORKER_SEQ_GEN__NEXT_A:

         $_chunk_id += $_max_workers;
         $_next      = ($_chunk_id - 1) * $_step + $_begin;
      }
   }
   else {                                         ## Chunking, yes.

      $self->{_next_jmp} = sub { goto _WORKER_SEQ_GEN__NEXT_B; };

      while (1) {
         my $_n_begin = $_next; my @_n = ();

         ## -------------------------------------------------------------------

         if ($_bounds_only) {
            my $_tmp_b = $_next; my $_tmp_e;

            if ($_begin < $_end) {
               if ($_step * $_chunk_size + $_n_begin <= $_end) {
                  $_tmp_e = $_step * ($_chunk_size - 1) + $_n_begin;
               }
               else {
                  my $_start = int(
                     ($_end - $_next) / $_chunk_size / $_step * $_chunk_size
                  );
                  $_start = 1 if ($_start < 1);

                  for ($_start .. $_chunk_size) {
                     last if ($_next > $_end);
                     $_tmp_e = $_next;
                     $_next  = $_step * $_ + $_n_begin;
                  }
               }
            }
            else {
               if ($_step * $_chunk_size + $_n_begin >= $_end) {
                  $_tmp_e = $_step * ($_chunk_size - 1) + $_n_begin;
               }
               else {
                  my $_start = int(
                     ($_next - $_end) / $_chunk_size / $_step * $_chunk_size
                  );
                  $_start = 1 if ($_start < 1);

                  for ($_start .. $_chunk_size) {
                     last if ($_next < $_end);
                     $_tmp_e = $_next;
                     $_next  = $_step * $_ + $_n_begin;
                  }
               }
            }

            return unless (defined $_tmp_e);

            if (defined $_fmt) {
               @_n = (sprintf("%$_fmt", $_tmp_b), sprintf("%$_fmt", $_tmp_e));
            } else {
               @_n = ($_tmp_b, $_tmp_e);
            }
         }

         ## -------------------------------------------------------------------

         else {
            if ($_begin < $_end) {
               if (!defined $_fmt && $_step == 1) {
                  if ($_next + $_chunk_size <= $_end) {
                     @_n = ($_next .. $_next + $_chunk_size - 1);
                  } else {
                     @_n = ($_next .. $_end);
                  }
               }
               else {
                  for (1 .. $_chunk_size) {
                     last if ($_next > $_end);

                     push @_n, (defined $_fmt)
                        ? sprintf("%$_fmt", $_next) : $_next;

                     $_next = $_step * $_ + $_n_begin;
                  }
               }
            }
            else {
               for (1 .. $_chunk_size) {
                  last if ($_next < $_end);

                  push @_n, (defined $_fmt)
                     ? sprintf("%$_fmt", $_next) : $_next;

                  $_next = $_step * $_ + $_n_begin;
               }
            }

            return unless (@_n > 0);
         }

         ## -------------------------------------------------------------------

         local $_ = \@_n;
         $_wuf->($self, \@_n, $_chunk_id);

         _WORKER_SEQ_GEN__NEXT_B:

         $_chunk_id += $_max_workers;
         $_next      = ($_chunk_id - 1) * $_chunk_size * $_step + $_begin;
      }
   }

   _WORKER_SEQ_GEN__LAST:

   return;
}

1;

