use strict;
use warnings;

use RT::Test tests => undef;

my $queue_a = RT::Test->load_or_create_queue( Name => 'EquivA' );
ok $queue_a && $queue_a->id, 'loaded or created queue A';

my $queue_b = RT::Test->load_or_create_queue( Name => 'EquivB' );
ok $queue_b && $queue_b->id, 'loaded or created queue B';

my $user = RT::Test->load_or_create_user(
    Name         => 'equivuser',
    Password     => 'password',
    EmailAddress => 'equiv@example.com',
);
ok $user && $user->id, 'loaded or created user';

RT::Test->set_rights(
    { Principal => 'Everyone', Right => ['SeeQueue'],  Object => $queue_a },
    { Principal => 'Everyone', Right => ['OwnTicket'], Object => $queue_b },
);

my ($ticket) = RT::Test->create_tickets( { Queue => $queue_a->id }, {} );
ok $ticket && $ticket->id, 'created ticket in queue A';

my $principal = $user->PrincipalObj;

# Ask for the rights on the ticket with queue B as an extra equivalence
# object. Queue B contributes OwnTicket, queue A contributes SeeQueue.
my $with_equiv = $principal->HasRights(
    Object       => $ticket,
    EquivObjects => [$queue_b],
);
ok $with_equiv->{OwnTicket}, 'extra equivalence object contributes OwnTicket';
ok $with_equiv->{SeeQueue},  'the ticket own queue contributes SeeQueue';

# The same question without the extra equivalence object must not reuse the
# cached answer that included queue B.
my $without_equiv = $principal->HasRights( Object => $ticket );
ok !$without_equiv->{OwnTicket}, 'cache key separates results with and without EquivObjects';
ok $without_equiv->{SeeQueue},   'rights from the ticket own queue are still present';

# A fresh cache computes the same answer as the cache hit above.
{
    local $RT::Principal::_ACL_CACHE = {};
    my $fresh = $principal->HasRights( Object => $ticket );
    is_deeply( $fresh, $without_equiv, 'cached answer matches a fresh computation' );
}

done_testing();
