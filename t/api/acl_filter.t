use strict;
use warnings;

use RT::Test nodata => 1, tests => undef;

my $queue = RT::Test->load_or_create_queue( Name => 'ACLFilter' );
ok $queue && $queue->id, 'loaded or created queue';

my $viewer = RT::Test->load_or_create_user(
    Name         => 'aclviewer',
    Password     => 'password',
    EmailAddress => 'viewer@example.com',
);
ok $viewer && $viewer->id, 'loaded or created viewer';

my $blind = RT::Test->load_or_create_user(
    Name         => 'aclblind',
    Password     => 'password',
    EmailAddress => 'blind@example.com',
);
ok $blind && $blind->id, 'loaded or created user without ACL rights';

my @groups;
for my $name (qw(AclFilterAlpha AclFilterBeta AclFilterGamma)) {
    my $group = RT::Group->new( RT->SystemUser );
    my ( $gid, $gmsg ) = $group->CreateUserDefinedGroup( Name => $name );
    ok $gid, "created group $name: $gmsg";
    push @groups, $group;
}

RT::Test->add_rights(
    map {
        { Principal => $_->PrincipalObj, Right => ['ShowTicket'], Object => $queue }
    } @groups
);

RT::Test->add_rights(
    { Principal => $viewer->PrincipalObj, Right => ['ShowACL'] }
);

sub acl_for_queue {
    my $user = shift;
    my $acls = RT::ACL->new( RT::CurrentUser->new($user) );
    $acls->LimitToObject($queue);
    return $acls;
}

note "a user with ShowACL sees every ACE, and the object is loaded once";
{
    my $acls = acl_for_queue($viewer);

    my $loads = 0;
    my $original_load = \&RT::Queue::Load;

    my @seen;
    {
        no warnings 'redefine';
        local *RT::Queue::Load = sub {
            $loads++;
            return $original_load->(@_);
        };

        while ( my $ace = $acls->Next ) {
            push @seen, $ace->id;
        }
    }

    is scalar @seen, 3, 'three ACEs were returned';
    is $loads, 1, 'the shared object was loaded once for three rows';
}

note "a user without ShowACL or ModifyACL still gets no rows";
{
    my $acls = acl_for_queue($blind);

    my @seen;
    while ( my $ace = $acls->Next ) {
        push @seen, $ace->id;
    }

    is scalar @seen, 0, 'every row was filtered out';
}

note "a collection that spans two objects keeps both checks separate";
{
    my $second = RT::Test->load_or_create_queue( Name => 'ACLFilterTwo' );
    ok $second && $second->id, 'loaded or created second queue';

    RT::Test->add_rights(
        { Principal => $groups[0]->PrincipalObj, Right => ['ShowTicket'], Object => $second },
    );

    my $acls = RT::ACL->new( RT::CurrentUser->new($viewer) );
    $acls->Limit( FIELD => 'ObjectType', VALUE => 'RT::Queue' );
    $acls->Limit(
        FIELD           => 'ObjectId',
        VALUE           => [ $queue->id, $second->id ],
        OPERATOR        => 'IN',
        ENTRYAGGREGATOR => 'AND',
    );

    my $count = 0;
    $count++ while $acls->Next;
    ok $count > 3, 'rows for both queues were returned';
}

done_testing();
