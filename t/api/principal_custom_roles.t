use strict;
use warnings;

# ACL-4: the rights code used to load every custom role named by the ACL and
# ask IsAdded for every object, which is one query per role. The filter is now
# answered by one query for the whole set. These tests pin both the answer
# (disabled roles, roles removed from the queue, ordinary roles) and the query
# count.

use RT::Test tests => undef;

my $queue = RT::Test->load_or_create_queue( Name => 'CustomRoleFilter' );
ok $queue && $queue->id, 'queue';

my $user = RT::Test->load_or_create_user(
    Name         => 'customrolefilteruser',
    Password     => 'password',
    EmailAddress => 'customrolefilter@example.com',
    Privileged   => 1,
);
ok $user && $user->id, 'user';

sub add_role {
    my ($name) = @_;

    my $role = RT::CustomRole->new( RT->SystemUser );
    my ( $created, $create_msg ) = $role->Create( Name => $name );
    ok $created, "created role $name: $create_msg";

    my ( $added, $add_msg ) = $role->AddToObject( $queue->Id );
    ok $added, "added $name to the queue: $add_msg";

    return $role;
}

sub role_group {
    my ($role) = @_;

    my $group = RT::Group->new( RT->SystemUser );
    $group->LoadRoleGroup( Object => $queue, Name => $role->GroupType );
    ok $group->id, 'loaded the role group for ' . $role->Name;
    return $group;
}

sub grant_show_ticket {
    my ($group) = @_;

    my ( $granted, $grant_msg )
        = $group->PrincipalObj->GrantRight( Right => 'ShowTicket', Object => $queue );
    ok $granted, 'granted ShowTicket to ' . $group->Name . ": $grant_msg";
}

my $role_one     = add_role('filter-one');
my $role_two     = add_role('filter-two');
my $role_disabled = add_role('filter-disabled');
my $role_removed = add_role('filter-removed');

my $group_one      = role_group($role_one);
my $group_two      = role_group($role_two);
my $group_disabled = role_group($role_disabled);
my $group_removed  = role_group($role_removed);

# Every role holds an ACE on the queue, so every one of them is a candidate for
# the role query. Being added to the queue and not disabled is what decides.
grant_show_ticket($_) for $group_one, $group_two, $group_disabled, $group_removed;

# An ordinary (non-custom) role granted the same right must pass through.
my $cc_group = RT::Group->new( RT->SystemUser );
$cc_group->LoadRoleGroup( Object => $queue, Name => 'Cc' );
ok $cc_group->id, 'loaded the Cc role group';
grant_show_ticket($cc_group);

for my $group ( $group_one, $group_two, $group_disabled, $group_removed ) {
    my ( $member_ok, $member_msg ) = $group->AddMember( $user->PrincipalId );
    ok $member_ok, 'user is in ' . $group->Name . ": $member_msg";
}

my $principal = $user->PrincipalObj;

sub roles_with_right {
    my @roles = $principal->RolesWithRight(
        Right        => 'ShowTicket',
        EquivObjects => [$queue],
    );
    return [ sort @roles ];
}

sub custom_role_names {
    my $roles = shift;
    return [ grep {/^RT::CustomRole-/} @$roles ];
}

sub expected_roles {
    return [ 'Cc', sort map { $_->GroupType } @_ ];
}

is_deeply roles_with_right(),
    expected_roles( $role_one, $role_two, $role_disabled, $role_removed ),
    'the two live roles and the two candidates are reported';

note 'disabling a custom role removes it, re-enabling brings it back';
my ( $changed, $msg ) = $role_disabled->SetDisabled(1);
ok $changed, "disabled the custom role: $msg";
is_deeply roles_with_right(), expected_roles( $role_one, $role_two, $role_removed ),
    'the disabled custom role is filtered out';

( $changed, $msg ) = $role_disabled->SetDisabled(0);
ok $changed, "re-enabled the custom role: $msg";
is_deeply roles_with_right(),
    expected_roles( $role_one, $role_two, $role_disabled, $role_removed ),
    'the re-enabled custom role is reported again';

note 'removing a custom role from the queue removes it, even with its ACE left behind';
( $changed, $msg ) = $role_removed->RemoveFromObject( $queue->Id );
ok $changed, "removed the custom role from the queue: $msg";
{
    my $acl = RT::ACL->new( RT->SystemUser );
    $acl->Limit( FIELD => 'ObjectType', VALUE => 'RT::Queue' );
    $acl->Limit( FIELD => 'ObjectId', VALUE => $queue->id );
    ok scalar( grep { $_->PrincipalType eq $role_removed->GroupType } @{ $acl->ItemsArrayRef } ),
        'the stale ACE is still in the ACL, so only the added-to-queue check can drop it';
}
is_deeply roles_with_right(), expected_roles( $role_one, $role_two, $role_disabled ),
    'the removed custom role is filtered out';

note 'the whole filter costs one query, not one per custom role';
{
    RT::Principal->InvalidateACLCache;
    DBIx::SearchBuilder::Record::Cachable->FlushCache;

    my $handle = RT->DatabaseHandle;
    $handle->LogSQLStatements(1);
    $handle->ClearSQLStatementLog;

    my $roles = roles_with_right();

    my @log = $handle->SQLStatementLog;
    $handle->LogSQLStatements(0);

    my @object_custom_roles
        = grep { $_->[1] =~ /\bFROM\s+ObjectCustomRoles\b/i } @log;
    my @custom_roles = grep { $_->[1] =~ /\bFROM\s+CustomRoles\b/i } @log;

    is scalar @object_custom_roles, 1,
        'one ObjectCustomRoles query answers every candidate role';
    is scalar @custom_roles, 0,
        'no per-role CustomRoles load is needed';
    is_deeply custom_role_names($roles),
        [ sort map { $_->GroupType } $role_one, $role_two, $role_disabled ],
        'the three live roles are still reported';}

note 'HasRights applies the same filter to the rights it returns';
{
    RT::Principal->InvalidateACLCache;
    my $rights = $principal->HasRights( Object => $queue );
    ok $rights->{ShowTicket},
        'the user still has ShowTicket through a custom role';
}

done_testing();
