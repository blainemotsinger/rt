use strict;
use warnings;

use Scalar::Util qw(refaddr);

use RT::Test nodata => 1, tests => undef;

my $original_member = \&RT::Group::HasMemberRecursively;
my $original_right  = \&RT::Principal::HasRight;

# Counters used by the localized wrappers below.
my ( $member_calls, $right_calls ) = ( 0, 0 );

sub reset_calls {
    $member_calls = 0;
    $right_calls  = 0;
}

sub count_member {
    $member_calls++;
    return $original_member->(@_);
}

sub count_right {
    $right_calls++;
    return $original_right->(@_);
}

my $queue = RT::Test->load_or_create_queue( Name => 'Visibility' );
ok $queue && $queue->id, 'loaded or created queue';

my $user = RT::Test->load_or_create_user(
    Name         => 'aceuser',
    Password     => 'password',
    EmailAddress => 'ace@example.com',
);
ok $user && $user->id, 'loaded or created user';

my $other = RT::Test->load_or_create_user(
    Name         => 'aceother',
    Password     => 'password',
    EmailAddress => 'other@example.com',
);
ok $other && $other->id, 'loaded or created second user';

my $outsider = RT::Test->load_or_create_user(
    Name         => 'aceoutsider',
    Password     => 'password',
    EmailAddress => 'outsider@example.com',
);
ok $outsider && $outsider->id, 'loaded or created outsider';

my $group = RT::Group->new( RT->SystemUser );
my ( $gid, $gmsg ) = $group->CreateUserDefinedGroup( Name => 'acevisibility' );
ok $gid, "created group: $gmsg";

my ( $mid, $mmsg ) = $group->AddMember( $user->PrincipalId );
ok $mid, "added user to group: $mmsg";

RT::Test->add_rights(
    { Principal => $group->PrincipalObj, Right => ['ShowTicket'], Object => $queue },
    { Principal => $other->PrincipalObj, Right => ['ShowTicket'], Object => $queue },
    { Principal => $user->PrincipalObj,  Right => ['ShowACL'],    Object => $queue },
);

sub ace_for_principal {
    my $principal = shift;
    my $acls = RT::ACL->new( RT->SystemUser );
    $acls->LimitToObject($queue);
    $acls->Limit( FIELD => 'PrincipalId', VALUE => $principal->id );
    return $acls->First;
}

# RT never stores rights against a user; grants are canonicalized to the
# user's ACL equivalence group, so that is what an ACE row points at.
sub equiv_group {
    my $user = shift;
    my $group = RT::Group->new( RT->SystemUser );
    $group->LoadACLEquivalenceGroup( $user->PrincipalObj );
    return $group;
}

note "a member sees the ACE and the membership check runs once";
{
    my $stored = ace_for_principal( $group->PrincipalObj );
    ok $stored && $stored->id, 'group ACE exists';

    my $ace = RT::ACE->new( RT::CurrentUser->new($user) );
    $ace->Load( $stored->id );
    is $ace->id, $stored->id, 'loaded the ACE as the member user';

    # Warm the AvailableRights memo: building it calls SeeQueue through
    # RT::Queue::Lifecycle, which is not part of the per-ACE visibility check.
    $ace->Object->AvailableRights;

    reset_calls();
    no warnings 'redefine';
    local *RT::Group::HasMemberRecursively = \&count_member;
    local *RT::Principal::HasRight        = \&count_right;

    is $ace->ObjectType,    'RT::Queue',  'ObjectType is readable';
    is $ace->ObjectId,      $queue->id,   'ObjectId is readable';
    is $ace->PrincipalType, 'Group',      'PrincipalType is readable';
    ok $ace->Created,                     'Created is readable';

    is $member_calls, 1, 'four field reads performed one membership lookup';
    is $right_calls,  0, 'no ShowACL check was needed for a member';

    is $ace->RightName, 'ShowTicket', 'RightName still resolves through the same gate';
}

note "a group ACE the user is not in is visible only through ShowACL";
{
    my $stored = ace_for_principal( equiv_group($other)->PrincipalObj );
    ok $stored && $stored->id, 'user ACE exists, stored against the equivalence group';

    my $ace = RT::ACE->new( RT::CurrentUser->new($user) );
    $ace->Load( $stored->id );
    is $ace->id, $stored->id, 'loaded the ACE as a user with ShowACL';

    $ace->Object->AvailableRights;

    reset_calls();
    no warnings 'redefine';
    local *RT::Group::HasMemberRecursively = \&count_member;
    local *RT::Principal::HasRight        = \&count_right;

    is $ace->ObjectType,    'RT::Queue', 'ObjectType is readable';
    is $ace->ObjectId,      $queue->id,  'ObjectId is readable';
    is $ace->PrincipalType, 'Group',     'PrincipalType is readable';
    ok $ace->Created,                    'Created is readable';

    is $member_calls, 1, 'four field reads performed one membership lookup';
    is $right_calls,  1, 'four field reads performed one ShowACL check';

    is $ace->RightName, 'ShowTicket', 'RightName still resolves through the same gate';
}

note "a user with no access stays denied, and still checks only once";
{
    my $stored = ace_for_principal( $group->PrincipalObj );
    ok $stored && $stored->id, 'group ACE exists';

    my $ace = RT::ACE->new( RT::CurrentUser->new($outsider) );
    $ace->Load( $stored->id );

    reset_calls();
    no warnings 'redefine';
    local *RT::Group::HasMemberRecursively = \&count_member;
    local *RT::Principal::HasRight        = \&count_right;

    is $ace->ObjectType,    undef, 'ObjectType is hidden';
    is $ace->ObjectId,      undef, 'ObjectId is hidden';
    is $ace->PrincipalType, undef, 'PrincipalType is hidden';
    is $ace->Created,       undef, 'Created is hidden';

    is $member_calls, 1, 'denied reads performed one membership lookup';
    is $right_calls,  1, 'denied reads performed one ShowACL check';
}

note "canonicalization round-trips every registered right";
{
    my %registered;
    for my $class ( keys %RT::ACE::RIGHTS ) {
        $registered{ $_->{Name} } = 1
            for values %{ $RT::ACE::RIGHTS{$class} || {} };
    }

    my @wrong = grep {
        my $name = $_;
        ( RT::ACE->CanonicalizeRightName( lc $name ) // '' ) ne $name;
    } sort keys %registered;

    ok scalar( keys %registered ) > 50, 'found the registered right set';
    is_deeply \@wrong, [], 'every registered right canonicalizes to its registered name';

    is(
        RT::ACE->CanonicalizeRightName('showticket'), 'ShowTicket',
        'mixed case input canonicalizes',
    );
    is(
        RT::ACE->CanonicalizeRightName('NotARealRight'), undef,
        'unknown right returns undef',
    );
}

note "AvailableRights is memoized";
{
    is refaddr( RT::Queue->AvailableRights ), refaddr( RT::Queue->AvailableRights ),
        'class call returns the same hashref';
    is refaddr( $queue->AvailableRights ), refaddr( $queue->AvailableRights ),
        'instance call returns the same hashref';
    ok $queue->AvailableRights->{ShowTicket}, 'rights are still present';
}

done_testing();
