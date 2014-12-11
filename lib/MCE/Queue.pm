###############################################################################
## ----------------------------------------------------------------------------
## MCE::Queue - Hybrid queues (normal and priority) for Many-Core Engine.
##
###############################################################################

package MCE::Queue;

use strict;
use warnings;

## no critic (Subroutines::ProhibitExplicitReturnUndef)
## no critic (TestingAndDebugging::ProhibitNoStrict)

use Fcntl qw( :flock O_RDONLY );
use Socket qw( :crlf PF_UNIX PF_UNSPEC SOCK_STREAM );
use Scalar::Util qw( looks_like_number );
use bytes;

our $VERSION = '1.521';

###############################################################################
## ----------------------------------------------------------------------------
## Import routine.
##
###############################################################################

our ($HIGHEST, $LOWEST, $FIFO, $LIFO, $LILO, $FILO) = (1, 0, 1, 0, 1, 0);

our $PORDER  = $HIGHEST;
our $TYPE    = $FIFO;
our $FAST    = 0;

my $_loaded;

sub import {

   my $_class = shift; return if ($_loaded++);

   ## Process module arguments.
   while (my $_argument = shift) {
      my $_arg = lc $_argument;

      if ( $_arg eq 'porder' ) {
         _croak('MCE::Queue::import: (PORDER) must be 1 or 0')
            if (!defined $_[0] || ($_[0] ne '1' && $_[0] ne '0'));

         $MCE::Queue::PORDER = shift;
         next;
      }
      if ( $_arg eq 'type' ) {
         _croak('MCE::Queue::import: (TYPE) must be 1 or 0')
            if (!defined $_[0] || ($_[0] ne '1' && $_[0] ne '0'));

         $MCE::Queue::TYPE = shift;
         next;
      }
      if ( $_arg eq 'fast' ) {
         _croak('MCE::Queue::import: (FAST) must be 1 or 0')
            if (!defined $_[0] || ($_[0] ne '1' && $_[0] ne '0'));

         $MCE::Queue::FAST = shift;
         next;
      }

      _croak("MCE::Queue::import: ($_argument) is not a valid module argument");
   }

   ## Define public methods to internal methods.
   no strict 'refs'; no warnings 'redefine';

   if (defined $MCE::VERSION && MCE->wid == 0) {
      _mce_m_init();
   }
   else {
      *{ 'MCE::Queue::clear'      } = \&_clear;
      *{ 'MCE::Queue::enqueue'    } = \&_enqueue;
      *{ 'MCE::Queue::enqueuep'   } = \&_enqueuep;
      *{ 'MCE::Queue::dequeue'    } = \&_dequeue;
      *{ 'MCE::Queue::dequeue_nb' } = \&_dequeue;
      *{ 'MCE::Queue::pending'    } = \&_pending;
      *{ 'MCE::Queue::insert'     } = \&_insert;
      *{ 'MCE::Queue::insertp'    } = \&_insertp;
      *{ 'MCE::Queue::peek'       } = \&_peek;
      *{ 'MCE::Queue::peekp'      } = \&_peekp;
      *{ 'MCE::Queue::peekh'      } = \&_peekh;
      *{ 'MCE::Queue::heap'       } = \&_heap;
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Define constants & variables.
##
###############################################################################

use constant {

   MAX_DQ_DEPTH => 192,               ## Maximum dequeue notifications allowed

   OUTPUT_C_QUE => 'C~QUE',           ## Clear the queue

   OUTPUT_A_QUE => 'A~QUE',           ## Enqueue into queue (array)
   OUTPUT_A_QUP => 'A~QUP',           ## Enqueue into queue (array (p))
   OUTPUT_R_QUE => 'R~QUE',           ## Enqueue into queue (reference)
   OUTPUT_R_QUP => 'R~QUP',           ## Enqueue into queue (reference (p))
   OUTPUT_S_QUE => 'S~QUE',           ## Enqueue into queue (scalar)
   OUTPUT_S_QUP => 'S~QUP',           ## Enqueue into queue (scalar (p))

   OUTPUT_D_QUE => 'D~QUE',           ## Dequeue from queue (blocking)
   OUTPUT_D_QUN => 'D~QUN',           ## Dequeue from queue (non-blocking)

   OUTPUT_N_QUE => 'N~QUE',           ## Return the number of items

   OUTPUT_I_QUE => 'I~QUE',           ## Insert into queue
   OUTPUT_I_QUP => 'I~QUP',           ## Insert into queue (p)

   OUTPUT_P_QUE => 'P~QUE',           ## Peek into queue
   OUTPUT_P_QUP => 'P~QUP',           ## Peek into queue (p)
   OUTPUT_P_QUH => 'P~QUH',           ## Peek into heap

   OUTPUT_H_QUE => 'H~QUE'            ## Return the heap
};

## ** Attributes used internally and listed here.
## _datp _datq _heap _id _nb_flag _qr_sock _qw_sock _standalone _porder _type

my %_valid_fields_new = map { $_ => 1 } qw(
   gather porder queue type fast
);

my $_queues = {};
my $_qid    = 0;

sub DESTROY {

   my $_queue = $_[0];

   undef $_queue->{_datp}; undef $_queue->{_datq}; undef $_queue->{_heap};
   delete $_queues->{ $_queue->{_id} } if (exists $_queue->{_id});

   return if (defined $MCE::MCE && $MCE::MCE->wid);

   if (defined $_queue->{_qr_sock}) {
      local $!; local $?;

      CORE::shutdown $_queue->{_qw_sock}, 2;
      CORE::shutdown $_queue->{_qr_sock}, 2;

      close $_queue->{_qw_sock}; undef $_queue->{_qw_sock};
      close $_queue->{_qr_sock}; undef $_queue->{_qr_sock};
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## New instance instantiation.
##
###############################################################################

sub new {

   my ($_class, %_argv) = @_;

   @_ = ();

   my $_queue = {}; bless($_queue, ref($_class) || $_class);

   for (keys %_argv) {
      _croak("MCE::Queue::new: ($_) is not a valid constructor argument")
         unless (exists $_valid_fields_new{$_});
   }

   $_queue->{_datp} = {};  ## Priority data { p1 => [ ], p2 => [ ], pN => [ ] }
   $_queue->{_heap} = [];  ## Priority heap [ pN, p2, p1 ] ## in heap order
                           ## fyi, _datp will always dequeue before _datq

   $_queue->{_porder} = (exists $_argv{porder} && defined $_argv{porder})
      ? $_argv{porder} : $MCE::Queue::PORDER;
   $_queue->{_type} = (exists $_argv{type} && defined $_argv{type})
      ? $_argv{type} : $MCE::Queue::TYPE;
   $_queue->{_fast} = (exists $_argv{fast} && defined $_argv{fast})
      ? $_argv{fast} : $MCE::Queue::FAST;

   ## -------------------------------------------------------------------------

   _croak('MCE::Queue::new: (porder) must be 1 or 0')
      if ($_queue->{_porder} ne '1' && $_queue->{_porder} ne '0');
   _croak('MCE::Queue::new: (type) must be 1 or 0')
      if ($_queue->{_type} ne '1' && $_queue->{_type} ne '0');
   _croak('MCE::Queue::new: (fast) must be 1 or 0')
      if ($_queue->{_fast} ne '1' && $_queue->{_fast} ne '0');

   if (exists $_argv{queue}) {
      _croak('MCE::Queue::new: (queue) is not an ARRAY reference')
         if (ref $_argv{queue} ne 'ARRAY');

      $_queue->{_datq} = $_argv{queue};
   }
   else {
      $_queue->{_datq} = [];
   }

   if (exists $_argv{gather}) {
      _croak('MCE::Queue::new: (gather) is not a CODE reference')
         if (ref $_argv{gather} ne 'CODE');

      $_queue->{gather} = $_argv{gather};
   }

   ## -------------------------------------------------------------------------

   if (defined $MCE::VERSION) {
      if (MCE->wid == 0) {
         $_queue->{_id} = ++$_qid; $_queues->{$_qid} = $_queue;
         $_queue->{_desem} = 0 if ($_queue->{_fast});

         socketpair( $_queue->{_qr_sock}, $_queue->{_qw_sock},
            PF_UNIX, SOCK_STREAM, PF_UNSPEC ) or die "socketpair: $!\n";

         binmode $_queue->{_qr_sock};
         binmode $_queue->{_qw_sock};

         my $_old_hndl = select $_queue->{_qr_sock}; $| = 1;
                         select $_queue->{_qw_sock}; $| = 1;

         select $_old_hndl;

         syswrite $_queue->{_qw_sock}, $LF
            if (exists $_argv{queue} && scalar @{ $_argv{queue} });
      }
      else {
         $_queue->{_standalone} = 1;
      }
   }

   return $_queue;
}

###############################################################################
## ----------------------------------------------------------------------------
## Clear method.
##
###############################################################################

sub _clear {

   my $_queue = shift;

   %{ $_queue->{_datp} } = ();
   @{ $_queue->{_datq} } = ();
   @{ $_queue->{_heap} } = ();

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Enqueue methods.
##
###############################################################################

## Add items to the tail of the queue.

sub _enqueue {

   my $_queue = shift;

   ## Append item(s) into the queue.
   push @{ $_queue->{_datq} }, @_;

   return;
}

## Add items to the tail of the queue with priority level.

sub _enqueuep {

   my $_queue = shift; my $_p = shift;

   _croak('MCE::Queue::enqueuep: (priority) is not an integer')
      if (!looks_like_number($_p) || int($_p) != $_p);

   return unless (scalar @_);

   ## Enlist priority into the heap.
   if (!exists $_queue->{_datp}->{$_p} || @{ $_queue->{_datp}->{$_p} } == 0) {

      unless (scalar @{ $_queue->{_heap} }) {
         push @{ $_queue->{_heap} }, $_p;
      }
      elsif ($_queue->{_porder}) {
         $_queue->_heap_insert_high($_p);
      }
      else {
         $_queue->_heap_insert_low($_p);
      }
   }

   ## Append item(s) into the queue.
   push @{ $_queue->{_datp}->{$_p} }, @_;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Dequeue and pending methods.
##
###############################################################################

## Return item(s) from the queue.

sub _dequeue {

   my $_queue = $_[0];

   if (defined $_[1] && $_[1] ne '1') {
      my @_items; my $_c = $_[1];

      _croak('MCE::Queue::dequeue: (count argument) is not valid')
         if (!looks_like_number($_c) || int($_c) != $_c || $_c < 1);

      push(@_items, $_queue->_dequeue()) for (1 .. $_c);

      return @_items;
   }

   ## Return item from the non-priority queue.
   unless (scalar @{ $_queue->{_heap} }) {
      return ($_queue->{_type})
         ? shift @{ $_queue->{_datq} } : pop @{ $_queue->{_datq} };
   }

   my $_p = $_queue->{_heap}->[0];

   ## Delist priority from the heap when 1 item remains.
   shift @{ $_queue->{_heap} }
      if (@{ $_queue->{_datp}->{$_p} } == 1);

   ## Return item from the priority queue.
   return ($_queue->{_type})
      ? shift @{ $_queue->{_datp}->{$_p} } : pop @{ $_queue->{_datp}->{$_p} };
}

## Return the number of items in the queue.

sub _pending {

   my $_pending = 0; my $_queue = shift;

   $_pending += @{ $_queue->{_datp}->{$_} } for (@{ $_queue->{_heap} });
   $_pending += @{ $_queue->{_datq} };

   return $_pending;
}

###############################################################################
## ----------------------------------------------------------------------------
## Insert methods.
##
###############################################################################

## Insert items anywhere into the queue.

sub _insert {

   my $_queue = shift; my $_i = shift;

   _croak('MCE::Queue::insert: (index) is not an integer')
      if (!looks_like_number($_i) || int($_i) != $_i);

   return unless (scalar @_);

   if (abs($_i) > scalar @{ $_queue->{_datq} }) {
      if ($_i >= 0) {
         if ($_queue->{_type}) {
            push @{ $_queue->{_datq} }, @_;
         } else {
            unshift @{ $_queue->{_datq} }, @_;
         }
      }
      else {
         if ($_queue->{_type}) {
            unshift @{ $_queue->{_datq} }, @_;
         } else {
            push @{ $_queue->{_datq} }, @_;
         }
      }
   }
   else {
      if (!$_queue->{_type}) {
         $_i = ($_i >= 0)
            ? scalar(@{ $_queue->{_datq} }) - $_i
            : abs($_i);
      }
      splice @{ $_queue->{_datq} }, $_i, 0, @_;
   }

   return;
}

## Insert items anywhere into the queue with priority level.

sub _insertp {

   my $_queue = shift; my $_p = shift; my $_i = shift;

   _croak('MCE::Queue::insertp: (priority) is not an integer')
      if (!looks_like_number($_p) || int($_p) != $_p);
   _croak('MCE::Queue::insertp: (index) is not an integer')
      if (!looks_like_number($_i) || int($_i) != $_i);

   return unless (scalar @_);

   if (exists $_queue->{_datp}->{$_p} && scalar @{ $_queue->{_datp}->{$_p} }) {

      if (abs($_i) > scalar @{ $_queue->{_datp}->{$_p} }) {
         if ($_i >= 0) {
            if ($_queue->{_type}) {
               push @{ $_queue->{_datp}->{$_p} }, @_;
            } else {
               unshift @{ $_queue->{_datp}->{$_p} }, @_;
            }
         }
         else {
            if ($_queue->{_type}) {
               unshift @{ $_queue->{_datp}->{$_p} }, @_;
            } else {
               push @{ $_queue->{_datp}->{$_p} }, @_;
            }
         }
      }
      else {
         if (!$_queue->{_type}) {
            $_i = ($_i >=0)
               ? scalar(@{ $_queue->{_datp}->{$_p} }) - $_i
               : abs($_i);
         }
         splice @{ $_queue->{_datp}->{$_p} }, $_i, 0, @_;
      }
   }
   else {
      $_queue->_enqueuep($_p, @_);
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Peek and heap methods.
##
## Below, do not change 'return undef' statements to 'return'.
##
###############################################################################

## Return an item without removing it from the queue.

sub _peek {

   my $_queue = shift; my $_i = shift || 0;

   _croak('MCE::Queue::peek: (index) is not an integer')
      if (!looks_like_number($_i) || int($_i) != $_i);

   return undef if (abs($_i) > scalar @{ $_queue->{_datq} });

   if (!$_queue->{_type}) {
      $_i = ($_i >= 0)
         ? scalar(@{ $_queue->{_datq} }) - ($_i + 1)
         : abs($_i + 1);
   }

   return $_queue->{_datq}->[$_i];
}

## Return an item without removing it from the queue with priority level.

sub _peekp {

   my $_queue = shift; my $_p = shift; my $_i = shift || 0;

   _croak('MCE::Queue::peekp: (priority) is not an integer')
      if (!looks_like_number($_p) || int($_p) != $_p);
   _croak('MCE::Queue::peekp: (index) is not an integer')
      if (!looks_like_number($_i) || int($_i) != $_i);

   return undef unless (exists $_queue->{_datp}->{$_p});

   return undef if (abs($_i) > scalar @{ $_queue->{_datp}->{$_p} });

   if (!$_queue->{_type}) {
      $_i = ($_i >= 0)
         ? scalar(@{ $_queue->{_datp}->{$_p} }) - ($_i + 1)
         : abs($_i + 1);
   }

   return $_queue->{_datp}->{$_p}->[$_i];
}

## Return a priority level without removing it from the heap.

sub _peekh {

   my $_queue = shift; my $_i = shift || 0;

   _croak('MCE::Queue::peekh: (index) is not an integer')
      if (!looks_like_number($_i) || int($_i) != $_i);

   return undef if (abs($_i) > scalar @{ $_queue->{_heap} });

   return $_queue->{_heap}->[$_i];
}

## Return a list of priority levels in the heap.

sub _heap {

   return @{ shift->{_heap} };
}

###############################################################################
## ----------------------------------------------------------------------------
## Internal methods.
##
###############################################################################

sub _croak {

   unless (defined $MCE::VERSION) {
      $\ = undef; require Carp; goto &Carp::croak;
   } else {
      goto &MCE::_croak;
   }

   return;
}

## Helper method for getting the reference to the underlying array.
## Use with test scripts for comparing data only (not a public API).

sub _get_aref {

   my $_queue = shift; my $_p = shift;

   return if (defined $MCE::MCE && $MCE::MCE->wid);

   if (defined $_p) {
      _croak('MCE::Queue::_get_aref: (priority) is not an integer')
         if (!looks_like_number($_p) || int($_p) != $_p);

      return undef unless (exists $_queue->{_datp}->{$_p});

      return $_queue->{_datp}->{$_p};
   }

   return $_queue->{_datq};
}

## A quick method for just wanting to know if the queue has pending data.

sub _has_data {

   return (
      scalar @{ $_[0]->{_datq} } || scalar @{ $_[0]->{_heap} }
   ) ? 1 : 0;
}

## Insert priority into the heap. A lower priority level comes first.

sub _heap_insert_low {

   my $_queue = $_[0]; my $_p = $_[1];

   ## Insert priority at the head of the heap.
   if ($_p < $_queue->{_heap}->[0]) {
      unshift @{ $_queue->{_heap} }, $_p;
   }

   ## Insert priority at the end of the heap.
   elsif ($_p > $_queue->{_heap}->[-1]) {
      push @{ $_queue->{_heap} }, $_p;
   }

   ## Insert priority through binary search.
   else {
      my $_lower = 0; my $_upper = @{ $_queue->{_heap} };

      while ($_lower < $_upper) {
         my $_midpoint = ($_upper + $_lower) >> 1;

         if ($_p > $_queue->{_heap}->[$_midpoint]) {
            $_lower = $_midpoint + 1;
         } else {
            $_upper = $_midpoint;
         }
      }

      ## Insert priority into heap.
      splice @{ $_queue->{_heap} }, $_lower, 0, $_p;
   }

   return;
}

## Insert priority into the heap. A higher priority level comes first.

sub _heap_insert_high {

   my $_queue = $_[0]; my $_p = $_[1];

   ## Insert priority at the head of the heap.
   if ($_p > $_queue->{_heap}->[0]) {
      unshift @{ $_queue->{_heap} }, $_p;
   }

   ## Insert priority at the end of the heap.
   elsif ($_p < $_queue->{_heap}->[-1]) {
      push @{ $_queue->{_heap} }, $_p;
   }

   ## Insert priority through binary search.
   else {
      my $_lower = 0; my $_upper = @{ $_queue->{_heap} };

      while ($_lower < $_upper) {
         my $_midpoint = ($_upper + $_lower) >> 1;

         if ($_p < $_queue->{_heap}->[$_midpoint]) {
            $_lower = $_midpoint + 1;
         } else {
            $_upper = $_midpoint;
         }
      }

      ## Insert priority into heap.
      splice @{ $_queue->{_heap} }, $_lower, 0, $_p;
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Output routines for the MCE manager process.
##
###############################################################################

{
   my ($_MCE, $_DAU_R_SOCK_REF, $_DAU_R_SOCK, $_c, $_i, $_id);
   my ($_len, $_p, $_queue, $_pending);

   my %_output_function = (

      OUTPUT_C_QUE.$LF => sub {                   ## Clear the queue

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_id = <$_DAU_R_SOCK>);
         $_queue = $_queues->{$_id};

         sysread $_queue->{_qr_sock}, $_buffer, 1
            if ($_queue->_has_data());

         $_queue->_clear();

         print {$_DAU_R_SOCK} $LF;

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_A_QUE.$LF => sub {                   ## Enqueue into queue (A)

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buffer, $_len;

         $_queue = $_queues->{$_id};

         if ($_queue->{gather}) {
            local $_ = $_MCE->{thaw}($_buffer);
            $_queue->{gather}($_queue, @{ $_ });
         }
         else {
            syswrite $_queue->{_qw_sock}, $LF
               if (!$_queue->{_nb_flag} && !$_queue->_has_data());

            push @{ $_queue->{_datq} }, @{ $_MCE->{thaw}($_buffer) };
         }

         return;
      },

      OUTPUT_A_QUP.$LF => sub {                   ## Enqueue into queue (A,p)

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_p   = <$_DAU_R_SOCK>);
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buffer, $_len;

         $_queue = $_queues->{$_id};

         syswrite $_queue->{_qw_sock}, $LF
            if (!$_queue->{_nb_flag} && !$_queue->_has_data());

         $_queue->_enqueuep($_p, @{ $_MCE->{thaw}($_buffer) });

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_R_QUE.$LF => sub {                   ## Enqueue into queue (R)

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buffer, $_len;

         $_queue = $_queues->{$_id};

         if ($_queue->{gather}) {
            local $_ = $_MCE->{thaw}($_buffer);
            $_queue->{gather}($_queue, $_);
         }
         else {
            syswrite $_queue->{_qw_sock}, $LF
               if (!$_queue->{_nb_flag} && !$_queue->_has_data());

            push @{ $_queue->{_datq} }, $_MCE->{thaw}($_buffer);
         }

         return;
      },

      OUTPUT_R_QUP.$LF => sub {                   ## Enqueue into queue (R,p)

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_p   = <$_DAU_R_SOCK>);
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buffer, $_len;

         $_queue = $_queues->{$_id};

         syswrite $_queue->{_qw_sock}, $LF
            if (!$_queue->{_nb_flag} && !$_queue->_has_data());

         $_queue->_enqueuep($_p, $_MCE->{thaw}($_buffer));

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_S_QUE.$LF => sub {                   ## Enqueue into queue (S)

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buffer, $_len if ($_len >= 0);

         $_queue = $_queues->{$_id};

         if ($_queue->{gather}) {
            local $_ = $_buffer;
            $_queue->{gather}($_queue, $_);
         }
         else {
            syswrite $_queue->{_qw_sock}, $LF
               if (!$_queue->{_nb_flag} && !$_queue->_has_data());

            push @{ $_queue->{_datq} }, $_buffer;
         }

         return;
      },

      OUTPUT_S_QUP.$LF => sub {                   ## Enqueue into queue (S,p)

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_p   = <$_DAU_R_SOCK>);
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buffer, $_len if ($_len >= 0);

         $_queue = $_queues->{$_id};

         syswrite $_queue->{_qw_sock}, $LF
            if (!$_queue->{_nb_flag} && !$_queue->_has_data());

         $_queue->_enqueuep($_p, $_buffer);

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_D_QUE.$LF => sub {                   ## Dequeue from queue (B)

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_c  = <$_DAU_R_SOCK>); $_c = 0 if ($_c == 1);
         chomp($_id = <$_DAU_R_SOCK>);

         $_queue = $_queues->{$_id};

         my (@_items, $_buffer);

         if ($_c) {
            push(@_items, $_queue->_dequeue()) for (1 .. $_c);
         } else {
            $_buffer = $_queue->_dequeue();
         }

         if ($_queue->{_fast}) {
            ## The 'fast' option may reduce wait time, thus run faster
            if ($_queue->{_desem} <= 1) {
               $_pending = $_queue->_pending();
               $_pending = int($_pending / $_c) if ($_c);
               if ($_pending) {
                  $_pending = MAX_DQ_DEPTH if ($_pending > MAX_DQ_DEPTH);
                  syswrite $_queue->{_qw_sock}, $LF x $_pending;
               }
               $_queue->{_desem} = $_pending;
            }
            else {
               $_queue->{_desem} -= 1;
            }
         }
         else {
            ## Otherwise, never to exceed one byte in the channel
            syswrite $_queue->{_qw_sock}, $LF if ($_queue->_has_data());
         }

         if ($_c) {
            unless (defined $_items[0]) {
               print {$_DAU_R_SOCK} -1 . $LF;
            }
            else {
               $_buffer = $_MCE->{freeze}(\@_items);
               print {$_DAU_R_SOCK} length($_buffer) . $LF . $_buffer;
            }
         }
         else {
            unless (defined $_buffer) {
               print {$_DAU_R_SOCK} -1 . $LF;
            }
            else {
               if (ref $_buffer) {
                  $_buffer  = $_MCE->{freeze}($_buffer) . '1';
               } else {
                  $_buffer .= '0';
               }
               print {$_DAU_R_SOCK} length($_buffer) . $LF . $_buffer;
            }
         }

         $_queue->{_nb_flag} = 0;

         return;
      },

      OUTPUT_D_QUN.$LF => sub {                   ## Dequeue from queue (NB)

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_c  = <$_DAU_R_SOCK>);
         chomp($_id = <$_DAU_R_SOCK>);

         $_queue = $_queues->{$_id};

         if ($_c == 1) {
            my $_buffer = $_queue->_dequeue();

            unless (defined $_buffer) {
               print {$_DAU_R_SOCK} -1 . $LF;
            }
            else {
               if (ref $_buffer) {
                  $_buffer  = $_MCE->{freeze}($_buffer) . '1';
               } else {
                  $_buffer .= '0';
               }
               print {$_DAU_R_SOCK} length($_buffer) . $LF . $_buffer;
            }
         }
         else {
            my @_items; push(@_items, $_queue->_dequeue()) for (1 .. $_c);

            unless (defined $_items[0]) {
               print {$_DAU_R_SOCK} -1 . $LF;
            }
            else {
               my $_buffer = $_MCE->{freeze}(\@_items);
               print {$_DAU_R_SOCK} length($_buffer) . $LF . $_buffer;
            }
         }

         $_queue->{_nb_flag} = 1;

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_N_QUE.$LF => sub {                   ## Return number of items

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };

         chomp($_id = <$_DAU_R_SOCK>);

         print {$_DAU_R_SOCK} $_queues->{$_id}->_pending() . $LF;

         return;
      },

      OUTPUT_I_QUE.$LF => sub {                   ## Insert into queue

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_i   = <$_DAU_R_SOCK>);
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buffer, $_len;

         $_queue = $_queues->{$_id};

         syswrite $_queue->{_qw_sock}, $LF
            if (!$_queue->{_nb_flag} && !$_queue->_has_data());

         if (chop $_buffer) {
            $_queue->_insert($_i, @{ $_MCE->{thaw}($_buffer) });
         } else {
            $_queue->_insert($_i, $_buffer);
         }

         return;
      },

      OUTPUT_I_QUP.$LF => sub {                   ## Insert into queue (p)

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_p   = <$_DAU_R_SOCK>);
         chomp($_i   = <$_DAU_R_SOCK>);
         chomp($_id  = <$_DAU_R_SOCK>);
         chomp($_len = <$_DAU_R_SOCK>);
         read $_DAU_R_SOCK, $_buffer, $_len;

         $_queue = $_queues->{$_id};

         syswrite $_queue->{_qw_sock}, $LF
            if (!$_queue->{_nb_flag} && !$_queue->_has_data());

         if (chop $_buffer) {
            $_queue->_insertp($_p, $_i, @{ $_MCE->{thaw}($_buffer) });
         } else {
            $_queue->_insertp($_p, $_i, $_buffer);
         }

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_P_QUE.$LF => sub {                   ## Peek into queue

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_i  = <$_DAU_R_SOCK>);
         chomp($_id = <$_DAU_R_SOCK>);

         $_queue  = $_queues->{$_id};
         $_buffer = $_queue->_peek($_i);

         unless (defined $_buffer) {
            print {$_DAU_R_SOCK} -1 . $LF;
         }
         else {
            if (ref $_buffer) {
               $_buffer  = $_MCE->{freeze}($_buffer) . '1';
            } else {
               $_buffer .= '0';
            }
            print {$_DAU_R_SOCK} length($_buffer) . $LF . $_buffer;
         }

         return;
      },

      OUTPUT_P_QUP.$LF => sub {                   ## Peek into queue (p)

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_p  = <$_DAU_R_SOCK>);
         chomp($_i  = <$_DAU_R_SOCK>);
         chomp($_id = <$_DAU_R_SOCK>);

         $_queue  = $_queues->{$_id};
         $_buffer = $_queue->_peekp($_p, $_i);

         unless (defined $_buffer) {
            print {$_DAU_R_SOCK} -1 . $LF;
         }
         else {
            if (ref $_buffer) {
               $_buffer  = $_MCE->{freeze}($_buffer) . '1';
            } else {
               $_buffer .= '0';
            }
            print {$_DAU_R_SOCK} length($_buffer) . $LF . $_buffer;
         }

         return;
      },

      OUTPUT_P_QUH.$LF => sub {                   ## Peek into heap

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_i  = <$_DAU_R_SOCK>);
         chomp($_id = <$_DAU_R_SOCK>);

         $_queue  = $_queues->{$_id};
         $_buffer = $_queue->_peekh($_i);

         unless (defined $_buffer) {
            print {$_DAU_R_SOCK} -1 . $LF;
         } else {
            print {$_DAU_R_SOCK} length($_buffer) . $LF . $_buffer;
         }

         return;
      },

      ## ----------------------------------------------------------------------

      OUTPUT_H_QUE.$LF => sub {                   ## Return the heap

         $_DAU_R_SOCK = ${ $_DAU_R_SOCK_REF };
         my $_buffer;

         chomp($_id = <$_DAU_R_SOCK>);

         $_queue  = $_queues->{$_id};
         $_buffer = $_MCE->{freeze}([ $_queue->_heap() ]);

         print {$_DAU_R_SOCK} length($_buffer) . $LF . $_buffer;

         return;
      },

   );

   ## -------------------------------------------------------------------------

   sub _mce_m_loop_begin {

      $_MCE = $_[0]; $_DAU_R_SOCK_REF = $_[1];

      return;
   }

   sub _mce_m_loop_end {

      $_MCE = $_DAU_R_SOCK_REF = $_DAU_R_SOCK = $_c = $_i = $_id =
         $_len = $_p = $_queue = undef;

      return;
   }

   sub _mce_m_init {

      MCE::_attach_plugin(
         \%_output_function, \&_mce_m_loop_begin, \&_mce_m_loop_end,
         \&_mce_w_init
      );

      no strict 'refs'; no warnings 'redefine';

      *{ 'MCE::Queue::clear'      } = \&_mce_m_clear;
      *{ 'MCE::Queue::enqueue'    } = \&_mce_m_enqueue;
      *{ 'MCE::Queue::enqueuep'   } = \&_mce_m_enqueuep;
      *{ 'MCE::Queue::dequeue'    } = \&_mce_m_dequeue;
      *{ 'MCE::Queue::dequeue_nb' } = \&_mce_m_dequeue_nb;
      *{ 'MCE::Queue::insert'     } = \&_mce_m_insert;
      *{ 'MCE::Queue::insertp'    } = \&_mce_m_insertp;

      *{ 'MCE::Queue::pending'    } = \&_pending;
      *{ 'MCE::Queue::peek'       } = \&_peek;
      *{ 'MCE::Queue::peekp'      } = \&_peekp;
      *{ 'MCE::Queue::peekh'      } = \&_peekh;
      *{ 'MCE::Queue::heap'       } = \&_heap;

      return;
   }

}

###############################################################################
## ----------------------------------------------------------------------------
## Wrapper methods for the MCE manager process.
##
###############################################################################

sub _mce_m_clear {

   my $_next; my $_queue = shift;

   if ($_queue->{_fast}) {
      warn "MCE::Queue: (clear) not allowed for fast => 1\n";
   }
   else {
      sysread $_queue->{_qr_sock}, $_next, 1 if ($_queue->_has_data());
      $_queue->_clear();
   }

   return;
}

sub _mce_m_enqueue {

   my $_queue = shift;

   return unless (scalar @_);

   syswrite $_queue->{_qw_sock}, $LF
      if (!$_queue->{_nb_flag} && !$_queue->_has_data());

   push @{ $_queue->{_datq} }, @_;

   return;
}

sub _mce_m_enqueuep {

   my $_queue = shift; my $_p = shift;

   _croak('MCE::Queue::enqueuep: (priority) is not an integer')
      if (!looks_like_number($_p) || int($_p) != $_p);

   return unless (scalar @_);

   syswrite $_queue->{_qw_sock}, $LF
      if (!$_queue->{_nb_flag} && !$_queue->_has_data());

   $_queue->_enqueuep($_p, @_);

   return;
}

## ----------------------------------------------------------------------------

sub _mce_m_dequeue {

   my (@_items, $_buffer, $_c, $_next, $_pending); my $_queue = $_[0];

   sysread $_queue->{_qr_sock}, $_next, 1;        ## Wait here

   if (defined $_[1] && $_[1] ne '1') {
      $_c = $_[1]; @_items = $_queue->_dequeue($_c);
   } else {
      $_buffer = $_queue->_dequeue();
   }

   if ($_queue->{_fast}) {
      ## The 'fast' option may reduce wait time, thus run faster
      if ($_queue->{_desem} <= 1) {
         $_pending = $_queue->_pending();
         $_pending = int($_pending / $_c) if (defined $_c);
         if ($_pending) {
            $_pending = MAX_DQ_DEPTH if ($_pending > MAX_DQ_DEPTH);
            syswrite $_queue->{_qw_sock}, $LF x $_pending;
         }
         $_queue->{_desem} = $_pending;
      }
      else {
         $_queue->{_desem} -= 1;
      }
   }
   else {
      ## Otherwise, never to exceed one byte in the channel
      syswrite $_queue->{_qw_sock}, $LF if ($_queue->_has_data());
   }

   $_queue->{_nb_flag} = 0;

   return @_items if (defined $_c);
   return $_buffer;
}

sub _mce_m_dequeue_nb {

   my $_queue = $_[0];

   if ($_queue->{_fast}) {
      warn "MCE::Queue: (dequeue_nb) not allowed for fast => 1\n";
      return;
   }
   else {
      $_queue->{_nb_flag} = 1;

      return (defined $_[1] && $_[1] ne '1')
         ? $_queue->_dequeue($_[1]) : $_queue->_dequeue();
   }
}

## ----------------------------------------------------------------------------

sub _mce_m_insert {

   my $_queue = shift; my $_i = shift;

   _croak('MCE::Queue::insert: (index) is not an integer')
      if (!looks_like_number($_i) || int($_i) != $_i);

   return unless (scalar @_);

   syswrite $_queue->{_qw_sock}, $LF
      if (!$_queue->{_nb_flag} && !$_queue->_has_data());

   $_queue->_insert($_i, @_);

   return;
}

sub _mce_m_insertp {

   my $_queue = shift; my $_p = shift; my $_i = shift;

   _croak('MCE::Queue::insertp: (priority) is not an integer')
      if (!looks_like_number($_p) || int($_p) != $_p);

   _croak('MCE::Queue::insertp: (index) is not an integer')
      if (!looks_like_number($_i) || int($_i) != $_i);

   return unless (scalar @_);

   syswrite $_queue->{_qw_sock}, $LF
      if (!$_queue->{_nb_flag} && !$_queue->_has_data());

   $_queue->_insertp($_p, $_i, @_);

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Wrapper methods for the MCE worker process.
##
###############################################################################

{
   my ($_c, $_chn, $_lock_chn, $_len, $_next, $_pending, $_tag);
   my ($_MCE, $_DAT_LOCK, $_DAT_W_SOCK, $_DAU_W_SOCK);

   sub _mce_w_init {

      $_MCE = $_[0];

      $_chn        = $_MCE->{_chn};
      $_DAT_LOCK   = $_MCE->{_dat_lock};
      $_DAT_W_SOCK = $_MCE->{_dat_w_sock}->[0];
      $_DAU_W_SOCK = $_MCE->{_dat_w_sock}->[$_chn];
      $_lock_chn   = $_MCE->{_lock_chn};

      for (keys %{ $_queues }) {
         undef $_queues->{$_}->{_datp}; delete $_queues->{$_}->{_datp};
         undef $_queues->{$_}->{_datq}; delete $_queues->{$_}->{_datq};
         undef $_queues->{$_}->{_heap}; delete $_queues->{$_}->{_heap};
      }

      no strict 'refs'; no warnings 'redefine';

      *{ 'MCE::Queue::clear'      } = \&_mce_w_clear;
      *{ 'MCE::Queue::enqueue'    } = \&_mce_w_enqueue;
      *{ 'MCE::Queue::enqueuep'   } = \&_mce_w_enqueuep;
      *{ 'MCE::Queue::dequeue'    } = \&_mce_w_dequeue;
      *{ 'MCE::Queue::dequeue_nb' } = \&_mce_w_dequeue_nb;
      *{ 'MCE::Queue::pending'    } = \&_mce_w_pending;
      *{ 'MCE::Queue::insert'     } = \&_mce_w_insert;
      *{ 'MCE::Queue::insertp'    } = \&_mce_w_insertp;
      *{ 'MCE::Queue::peek'       } = \&_mce_w_peek;
      *{ 'MCE::Queue::peekp'      } = \&_mce_w_peekp;
      *{ 'MCE::Queue::peekh'      } = \&_mce_w_peekh;
      *{ 'MCE::Queue::heap'       } = \&_mce_w_heap;

      return;
   }

   ## -------------------------------------------------------------------------

   sub _mce_w_clear {

      my $_queue = shift;

      return $_queue->_clear() if (exists $_queue->{_standalone});

      if ($_queue->{_fast}) {
         warn "MCE::Queue: (clear) not allowed for fast => 1\n";
      }
      else {
         local $\ = undef if (defined $\);
         local $/ = $LF if (!$/ || $/ ne $LF);

         flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
         print {$_DAT_W_SOCK} OUTPUT_C_QUE . $LF . $_chn . $LF;
         print {$_DAU_W_SOCK} $_queue->{_id} . $LF;

         <$_DAU_W_SOCK>;
         flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
      }

      return;
   }

   ## -------------------------------------------------------------------------

   sub _mce_w_enqueue {

      my $_buffer; my $_queue = shift;

      return $_queue->_enqueue(@_) if (exists $_queue->{_standalone});

      if (@_ > 1) {
         $_tag = OUTPUT_A_QUE;
         $_buffer = $_MCE->{freeze}(\@_);
         $_buffer = $_queue->{_id} . $LF . length($_buffer) . $LF . $_buffer;
      }
      elsif (ref $_[0]) {
         $_tag = OUTPUT_R_QUE;
         $_buffer = $_MCE->{freeze}($_[0]);
         $_buffer = $_queue->{_id} . $LF . length($_buffer) . $LF . $_buffer;
      }
      elsif (scalar @_) {
         $_tag = OUTPUT_S_QUE;
         if (defined $_[0]) {
            $_buffer = $_queue->{_id} . $LF . length($_[0]) . $LF . $_[0];
         } else {
            $_buffer = $_queue->{_id} . $LF . -1 . $LF;
         }
      }

      local $\ = undef if (defined $\);

      flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
      print {$_DAT_W_SOCK} $_tag . $LF . $_chn . $LF;
      print {$_DAU_W_SOCK} $_buffer;
      flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

      return;
   }

   sub _mce_w_enqueuep {

      my $_buffer; my $_queue = shift; my $_p = shift;

      _croak('MCE::Queue::enqueuep: (priority) is not an integer')
         if (!looks_like_number($_p) || int($_p) != $_p);

      return $_queue->_enqueuep($_p, @_) if (exists $_queue->{_standalone});

      if (@_ > 1) {
         $_tag = OUTPUT_A_QUP;
         $_buffer = $_MCE->{freeze}(\@_);
         $_buffer = $_p . $LF . $_queue->{_id} . $LF .
            length($_buffer) . $LF . $_buffer;
      }
      elsif (ref $_[0]) {
         $_tag = OUTPUT_R_QUP;
         $_buffer = $_MCE->{freeze}($_[0]);
         $_buffer = $_p . $LF . $_queue->{_id} . $LF .
            length($_buffer) . $LF . $_buffer;
      }
      elsif (scalar @_) {
         $_tag = OUTPUT_S_QUP;
         if (defined $_[0]) {
            $_buffer = $_p . $LF . $_queue->{_id} . $LF .
               length($_[0]) . $LF . $_[0];
         }
         else {
            $_buffer = $_p . $LF . $_queue->{_id} . $LF .
               -1 . $LF;
         }
      }

      local $\ = undef if (defined $\);

      flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
      print {$_DAT_W_SOCK} $_tag . $LF . $_chn . $LF;
      print {$_DAU_W_SOCK} $_buffer;
      flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

      return;
   }

   ## -------------------------------------------------------------------------

   sub _mce_w_dequeue {

      my $_buffer; my $_queue = shift;

      return $_queue->_dequeue(@_) if (exists $_queue->{_standalone});

      if (defined $_[0] && $_[0] ne '1') {
         $_c = $_[0];
         _croak('MCE::Queue::dequeue: (count argument) is not valid')
            if (!looks_like_number($_c) || int($_c) != $_c || $_c < 1);
      }
      else {
         $_c = 1;
      }

      {
         local $\ = undef if (defined $\);
         local $/ = $LF if (!$/ || $/ ne $LF);

         sysread $_queue->{_qr_sock}, $_next, 1;  ## Wait here

         flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
         print {$_DAT_W_SOCK} OUTPUT_D_QUE . $LF . $_chn . $LF;
         print {$_DAU_W_SOCK} $_c . $LF . $_queue->{_id} . $LF;

         chomp($_len = <$_DAU_W_SOCK>);

         if ($_len < 0) {
            flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
            return undef;   # Do not change this to return;
         }

         read  $_DAU_W_SOCK, $_buffer, $_len;
         flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
      }

      if ($_c == 1) {
         return (chop $_buffer) ? $_MCE->{thaw}($_buffer) : $_buffer;
      } else {
         return @{ $_MCE->{thaw}($_buffer) };
      }
   }

   sub _mce_w_dequeue_nb {

      my $_buffer; my $_queue = shift;

      return $_queue->_dequeue(@_) if (exists $_queue->{_standalone});

      if ($_queue->{_fast}) {
         warn "MCE::Queue: (dequeue_nb) not allowed for fast => 1\n";
         return;
      }

      if (defined $_[0] && $_[0] ne '1') {
         $_c = $_[0];
         _croak('MCE::Queue::dequeue: (count argument) is not valid')
            if (!looks_like_number($_c) || int($_c) != $_c || $_c < 1);
      }
      else {
         $_c = 1;
      }

      {
         local $\ = undef if (defined $\);
         local $/ = $LF if (!$/ || $/ ne $LF);

         flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
         print {$_DAT_W_SOCK} OUTPUT_D_QUN . $LF . $_chn . $LF;
         print {$_DAU_W_SOCK} $_c . $LF . $_queue->{_id} . $LF;

         chomp($_len = <$_DAU_W_SOCK>);

         if ($_len < 0) {
            flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
            return undef;   # Do not change this to return;
         }

         read  $_DAU_W_SOCK, $_buffer, $_len;
         flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
      }

      if ($_c == 1) {
         return (chop $_buffer) ? $_MCE->{thaw}($_buffer) : $_buffer;
      } else {
         return @{ $_MCE->{thaw}($_buffer) };
      }
   }

   ## -------------------------------------------------------------------------

   sub _mce_w_pending {

      my $_queue = shift;

      return $_queue->_pending(@_) if (exists $_queue->{_standalone});

      local $\ = undef if (defined $\);
      local $/ = $LF if (!$/ || $/ ne $LF);

      flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
      print {$_DAT_W_SOCK} OUTPUT_N_QUE . $LF . $_chn . $LF;
      print {$_DAU_W_SOCK} $_queue->{_id} . $LF;

      chomp($_pending = <$_DAU_W_SOCK>);
      flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

      return $_pending;
   }

   sub _mce_w_insert {

      my $_buffer; my $_queue = shift; my $_i = shift;

      _croak('MCE::Queue::insert: (index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);

      return $_queue->_insert($_i, @_) if (exists $_queue->{_standalone});

      if (@_ > 1 || ref $_[0]) {
         $_buffer = $_MCE->{freeze}(\@_) . '1';
         $_buffer = $_i . $LF . $_queue->{_id} . $LF .
            length($_buffer) . $LF . $_buffer;
      }
      elsif (scalar @_) {
         $_buffer = $_i . $LF . $_queue->{_id} . $LF .
            (length($_[0]) + 1) . $LF . $_[0] . '0';
      }

      local $\ = undef if (defined $\);

      flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
      print {$_DAT_W_SOCK} OUTPUT_I_QUE . $LF . $_chn . $LF;
      print {$_DAU_W_SOCK} $_buffer;
      flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

      return;
   }

   sub _mce_w_insertp {

      my $_buffer; my $_queue = shift; my $_p = shift; my $_i = shift;

      _croak('MCE::Queue::insertp: (priority) is not an integer')
         if (!looks_like_number($_p) || int($_p) != $_p);

      _croak('MCE::Queue::insertp: (index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);

      return $_queue->_insertp($_p, $_i, @_) if (exists $_queue->{_standalone});

      if (@_ > 1 || ref $_[0]) {
         $_buffer = $_MCE->{freeze}(\@_) . '1';
         $_buffer = $_p . $LF . $_i . $LF . $_queue->{_id} . $LF .
            length($_buffer) . $LF . $_buffer;
      }
      elsif (scalar @_) {
         $_buffer = $_p . $LF . $_i . $LF . $_queue->{_id} . $LF .
            (length($_[0]) + 1) . $LF . $_[0] . '0';
      }

      local $\ = undef if (defined $\);

      flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
      print {$_DAT_W_SOCK} OUTPUT_I_QUP . $LF . $_chn . $LF;
      print {$_DAU_W_SOCK} $_buffer;
      flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);

      return;
   }

   ## -------------------------------------------------------------------------

   sub _mce_w_peek {

      my $_buffer; my $_queue = shift; my $_i = shift || 0;

      _croak('MCE::Queue::peek: (index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);

      return $_queue->_peek($_i, @_) if (exists $_queue->{_standalone});

      {
         local $\ = undef if (defined $\);
         local $/ = $LF if (!$/ || $/ ne $LF);

         flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
         print {$_DAT_W_SOCK} OUTPUT_P_QUE . $LF . $_chn . $LF;
         print {$_DAU_W_SOCK} $_i . $LF . $_queue->{_id} . $LF;

         chomp($_len = <$_DAU_W_SOCK>);

         if ($_len < 0) {
            flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
            return undef;   # Do not change this to return;
         }

         read  $_DAU_W_SOCK, $_buffer, $_len;
         flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
      }

      return (chop $_buffer) ? $_MCE->{thaw}($_buffer) : $_buffer;
   }

   sub _mce_w_peekp {

      my $_buffer; my $_queue = shift; my $_p = shift; my $_i = shift || 0;

      _croak('MCE::Queue::peekp: (priority) is not an integer')
         if (!looks_like_number($_p) || int($_p) != $_p);

      _croak('MCE::Queue::peekp: (index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);

      return $_queue->_peekp($_p, $_i, @_) if (exists $_queue->{_standalone});

      {
         local $\ = undef if (defined $\);
         local $/ = $LF if (!$/ || $/ ne $LF);

         flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
         print {$_DAT_W_SOCK} OUTPUT_P_QUP . $LF . $_chn . $LF;
         print {$_DAU_W_SOCK} $_p . $LF . $_i . $LF . $_queue->{_id} . $LF;

         chomp($_len = <$_DAU_W_SOCK>);

         if ($_len < 0) {
            flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
            return undef;   # Do not change this to return;
         }

         read  $_DAU_W_SOCK, $_buffer, $_len;
         flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
      }

      return (chop $_buffer) ? $_MCE->{thaw}($_buffer) : $_buffer;
   }

   sub _mce_w_peekh {

      my $_buffer; my $_queue = shift; my $_i = shift || 0;

      _croak('MCE::Queue::peekh: (index) is not an integer')
         if (!looks_like_number($_i) || int($_i) != $_i);

      return $_queue->_peekh($_i, @_) if (exists $_queue->{_standalone});

      {
         local $\ = undef if (defined $\);
         local $/ = $LF if (!$/ || $/ ne $LF);

         flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
         print {$_DAT_W_SOCK} OUTPUT_P_QUH . $LF . $_chn . $LF;
         print {$_DAU_W_SOCK} $_i . $LF . $_queue->{_id} . $LF;

         chomp($_len = <$_DAU_W_SOCK>);

         if ($_len < 0) {
            flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
            return undef;   # Do not change this to return;
         }

         read  $_DAU_W_SOCK, $_buffer, $_len;
         flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
      }

      return $_buffer;
   }

   ## -------------------------------------------------------------------------

   sub _mce_w_heap {

      my $_buffer; my $_queue = shift;

      return $_queue->_heap(@_) if (exists $_queue->{_standalone});

      {
         local $\ = undef if (defined $\);
         local $/ = $LF if (!$/ || $/ ne $LF);

         flock $_DAT_LOCK, LOCK_EX if ($_lock_chn);
         print {$_DAT_W_SOCK} OUTPUT_H_QUE . $LF . $_chn . $LF;
         print {$_DAU_W_SOCK} $_queue->{_id} . $LF;

         chomp($_len = <$_DAU_W_SOCK>);

         read  $_DAU_W_SOCK, $_buffer, $_len;
         flock $_DAT_LOCK, LOCK_UN if ($_lock_chn);
      }

      return @{ $_MCE->{thaw}($_buffer) };
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

MCE::Queue - Hybrid queues (normal and priority) for Many-Core Engine

=head1 VERSION

This document describes MCE::Queue version 1.521

=head1 SYNOPSIS

   use MCE;
   use MCE::Queue;

   my $F = MCE::Queue->new(fast => 1);
   my $consumers = 8;

   my $mce = MCE->new(

      task_end => sub {
         my ($mce, $task_id, $task_name) = @_;

         $F->enqueue((undef) x $consumers)
            if $task_name eq 'dir';
      },

      user_tasks => [{
         max_workers => 1, task_name => 'dir',

         user_func => sub {
            ## Create a "standalone queue" only accessable to this worker.
            ## See included examples for running with multiple workers.
            my $D = MCE::Queue->new(queue => [ MCE->user_args->[0] ]);

            while (defined (my $dir = $D->dequeue_nb)) {
               my (@files, @dirs); foreach (glob("$dir/*")) {
                  if (-d $_) { push @dirs, $_; next; }
                  push @files, $_;
               }
               $D->enqueue(@dirs ) if scalar @dirs;
               $F->enqueue(@files) if scalar @files;
            }
         }
      },{
         max_workers => $consumers, task_name => 'file',

         user_func => sub {
            while (defined (my $file = $F->dequeue)) {
               MCE->say($file);
            }
         }
      }]

   )->run({ user_args => [ $ARGV[0] || '.' ] });

   __END__

   Results from files_mce.pl and files_thr.pl; included with MCE.
   Usage:
      time ./files_mce.pl /usr 0 | wc -l
      time ./files_mce.pl /usr 1 | wc -l
      time ./files_thr.pl /usr   | wc -l

   Darwin (OS)    /usr:    216,271 files
      MCE::Queue, fast => 0 :    4.17s
      MCE::Queue, fast => 1 :    2.62s
      Thread::Queue         :    4.14s

   Linux (VM)     /usr:    186,154 files
      MCE::Queue, fast => 0 :   12.57s
      MCE::Queue, fast => 1 :    3.36s
      Thread::Queue         :    5.91s

   Solaris (VM)   /usr:    603,051 files
      MCE::Queue, fast => 0 :   39.04s
      MCE::Queue, fast => 1 :   18.08s
      Thread::Queue      * Perl not built to support threads

=head1 DESCRIPTION

This module provides a queue interface supporting normal and priority queues
and utilizing the IPC engine behind MCE. Data resides under the manager
process. MCE::Queue also allows for a worker to create any number of queues
locally not available to other workers including the manager process. Think
of a CPU having L3 (shared) and L1 (local) cache.

=head1 IMPORT

Three options are available for overriding the default value for new queues.
The porder option applies to priority queues only.

   use MCE::Queue porder => $MCE::Queue::HIGHEST,
                  type   => $MCE::Queue::FIFO,
                  fast   => 0;

   use MCE::Queue;                # Same as above

   ## Possible values

   porder => $MCE::Queue::HIGHEST # Highest priority items dequeue first
             $MCE::Queue::LOWEST  # Lowest priority items dequeue first

   type   => $MCE::Queue::FIFO    # First in, first out
             $MCE::Queue::LIFO    # Last in, first out
             $MCE::Queue::LILO    # (Synonym for FIFO)
             $MCE::Queue::FILO    # (Synonym for LIFO)

=head1 THREE RUN MODES

MCE::Queue can be utilized under the following conditions:

    A) use MCE;           B) use MCE::Queue;    C) use MCE::Queue;
       use MCE::Queue;       use MCE;

=over 3

=item A) MCE is included prior to inclusion of MCE::Queue

The dequeue method blocks for the manager process including workers. All data
resides under the manager process. Workers send/request data via IPC.

Creating a queue from within the worker process will cause the queue to run in
local mode (C). The data resides under the worker process and not available to
other workers including the manager process.

=item B) MCE::Queue is included prior to inclusion of MCE

Queues behave as if running in local mode for the manager and worker processes
for the duration of the script. I cannot think of a use-case for this, but
mentioning the behavior in the event MCE::Queue is included prior to MCE.

=item C) MCE::Queue without inclusion of MCE

The dequeue method is non-blocking. Queues behave similarly to local queuing.
This mode is efficient due to minimum overhead and zero IPC behind the scene.
Hence, MCE is not required to use MCE::Queue.

=back

=head1 API DOCUMENTATION

=over 3

=item ->new ( [ queue => \@array ] )

This creates a new queue. Available options are queue, porder, type, fast, and
gather. The gather option is mainly for running with MCE and wanting to pass
item(s) to a callback function for appending to the queue.

The 'fast' option speeds up ->dequeue ops and not enabled by default. It is
beneficial for queues not calling ->clear or ->dequeue_nb and not altering the
optional count value while running; e.g. ->dequeue($count). Basically, do not
enable 'fast' if varying $count dynamically.

   use MCE;
   use MCE::Queue;

   my $q1 = MCE::Queue->new();
   my $q2 = MCE::Queue->new( queue => [ 0, 1, 2 ] );

   my $q3 = MCE::Queue->new( porder => $MCE::Queue::HIGHEST );
   my $q4 = MCE::Queue->new( porder => $MCE::Queue::LOWEST  );

   my $q5 = MCE::Queue->new( type => $MCE::Queue::FIFO );
   my $q6 = MCE::Queue->new( type => $MCE::Queue::LIFO );

   my $q7 = MCE::Queue->new( fast => 1 );

Multiple queues may point to the same callback function. The first argument
for the callback is the queue object.

   sub _append {
      my ($q, @items) = @_;
      $q->enqueue(@items);
   }

   my $q7 = MCE::Queue->new( gather => \&_append );
   my $q8 = MCE::Queue->new( gather => \&_append );

   ## Items are diverted to the gather callback function.
   $q7->enqueue( 'apple', 'orange' );

The gather option allows one to store items temporarily while ensuring output
order. Although a queue object is not required, this is simply a demonstration
of the gather option in the context of a queue.

   use MCE;
   use MCE::Queue;

   my ($_order_id, %_tmp);

   sub _preserve_order {
      my ($q, $chunk_id, $result) = @_;

      $_tmp{$chunk_id} = $result;

      while (1) {
         last unless exists $_tmp{$_order_id};
         $q->enqueue( $_tmp{$_order_id} );
         delete $_tmp{$_order_id++};
      }

      return;
   }

   my @squares; my $q = MCE::Queue->new(
      queue => \@squares, gather => \&_preserve_order
   );

   $_order_id = 1;  ## The first chunk_id equals 1;

   my $mce = MCE->new(
      chunk_size => 1, input_data => [ 1 .. 100 ],
      user_func => sub {
         $q->enqueue( MCE->chunk_id, $_ * $_ );
      }
   );

   $mce->run;

   print "@squares\n";

=item ->clear ( void )

Clears the queue of any items. This has the effect of nulling the queue.
Each queue comes with a socket for blocking behind the scene. Use the clear
method when wanting to clear the content of the array.

   my @a; my $q = MCE::Queue->new( queue => \@a );

   @a = ();     ## bad, the blocking socket may become out of sync
   $q->clear;   ## ok

=item ->enqueue ( $item [, $item, ... ] )

Appends a list of items onto the end of the normal queue.

=item ->enqueuep ( $p, $item [, $item, ... ] )

Appends a list of items onto the end of the priority queue with priority.

=item ->dequeue ( [ $count ] )

Returns the requested number of items (default is 1) from the queue. Priority
data will always dequeue first before any data from the normal queue.

The method will block if the queue contains zero items. If the queue contains
fewer than the requested number of items, the method will not block, but
return the remaining items and undef for up to the count requested.

The $count, used for requesting the number of items, is beneficial when workers
are passing parameters through the queue. For this release, always remember to
dequeue using the same multiple for the count. This is unlike Thread::Queue
which will block until the requested number of items are available.

=item ->dequeue_nb ( [ $count ] )

Returns the requested number of items (default is 1) from the queue. Like with
dequeue, priority data will always dequeue first. This method is non-blocking
and will return undef in the absence of data from the queue.

=item ->insert ( $index, $item [, $item, ... ] )

Adds the list of items to the queue at the specified index position (0 is the
head of the list). The head of the queue is that item which would be removed
by a call to dequeue.

   $q = MCE::Queue->new( type => $MCE::Queue::FIFO );
   $q->enqueue(1, 2, 3, 4);
   $q->insert(1, 'foo', 'bar'); 
   # Queue now contains: 1, foo, bar, 2, 3, 4

   $q = MCE::Queue->new( type => $MCE::Queue::LIFO );
   $q->enqueue(1, 2, 3, 4);
   $q->insert(1, 'foo', 'bar'); 
   # Queue now contains: 1, 2, 3, 'foo', 'bar', 4

=item ->insertp ( $p, $index, $item [, $item, ... ] )

Adds the list of items to the queue at the specified index position with
priority. The behavior is similarly to insert otherwise.

=item ->pending ( void )

Returns the number of items in the queue. The count includes both normal
and priority data.

   $q = MCE::Queue->new();
   $q->enqueuep(5, 'foo', 'bar');   # priority queue
   $q->enqueue('sunny', 'day');     # normal queue

   print $q->pending(), "\n";
   # Output: 4

=item ->peek ( [ $index ] )

Returns an item from the normal queue, at the specified index, without
dequeuing anything. It defaults to the head of the queue if index is not
specified. The head of the queue is that item which would be removed by a
call to dequeue. Negative index values are supported, similarly to arrays.

   $q = MCE::Queue->new( type => $MCE::Queue::FIFO );
   $q->enqueue(1, 2, 3, 4, 5);

   print $q->peek(1), ' ', $q->peek(-2), "\n";
   # Output: 2 4

   $q = MCE::Queue->new( type => $MCE::Queue::LIFO );
   $q->enqueue(1, 2, 3, 4, 5);

   print $q->peek(1), ' ', $q->peek(-2), "\n";
   # Output: 4 2

=item ->peekp ( $p [, $index ] )

Returns an item from the queue with priority, at the specified index, without
dequeuing anything. It defaults to the head of the queue if index is not
specified. The behavior is similarly to peek otherwise

=item ->peekh ( [ $index ] )

Returns an item from the heap, at the specified index.

   $q = MCE::Queue->new( porder => $MCE::Queue::HIGHEST );
   $q->enqueuep(5, 'foo');
   $q->enqueuep(6, 'bar');
   $q->enqueuep(4, 'sun');

   print $q->peekh(0), "\n";
   # Output: 6

   $q = MCE::Queue->new( porder => $MCE::Queue::LOWEST );
   $q->enqueuep(5, 'foo');
   $q->enqueuep(6, 'bar');
   $q->enqueuep(4, 'sun');

   print $q->peekh(0), "\n";
   # Output: 4

=item ->heap ( void )

Returns an array containing the heap data. Heap data consists of priority
numbers, not the data.

   @h = $q->heap;   # $MCE::Queue::HIGHEST
   # Heap contains: 6, 5, 4
   
   @h = $q->heap;   # $MCE::Queue::LOWEST
   # Heap contains: 4, 5, 6

=back

=head1 ACKNOWLEDGEMENTS

=over 3

=item L<POE::Queue::Array|POE::Queue::Array>

Two if statements were adopted for checking if the item belongs at the end or
head of the queue.

=item L<List::BinarySearch|List::BinarySearch>

The bsearch_num_pos method is helpful for accommodating highest/lowest order.

=item L<List::Priority|List::Priority>

MCE::Queue supports both normal and priority queues.

=item L<Thread::Queue|Thread::Queue>

Thread::Queue is used as a template for identifying and documenting the methods.
MCE::Queue is not fully compatible due to supporting normal and priority queues
simultaneously. E.g.

   $q->enqueuep( $p, $item [, $item, ... ] );    ## Priority queue
   $q->enqueue( $item [, $item, ... ] );         ## Normal queue

   $q->dequeue( [ $count ] );      ## Priority data dequeues first
   $q->dequeue_nb( [ $count ] );   ## Behavior is not the same

   $q->pending();                  ## Counts both normal/priority data
                                   ## in the queue

=item L<Parallel::DataPipe|Parallel::DataPipe>

The recursion example, in the sysopsis above, was largely adopted from this
module.

=back

=head1 INDEX

L<MCE|MCE>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.

=cut

