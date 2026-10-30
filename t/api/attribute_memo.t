use strict;
use warnings;

use Scalar::Util qw(refaddr);

use RT::Test tests => undef;

my $creator = RT::User->new(RT->SystemUser);
my ( $uid, $umsg ) = $creator->Create(
    Name         => 'attrmemo' . $$,
    EmailAddress => 'attrmemo' . $$ . '@example.com',
);
ok $uid, "created user: $umsg";

my $user = RT::User->new( RT::SystemUser );
$user->Load($uid);
is $user->Id, $uid, 'loaded the user';

my ( $ok, $msg ) = $user->PrincipalObj->GrantRight( Right => 'ModifySelf' );
ok $ok, "granted ModifySelf: $msg";

( $ok, $msg ) = $user->SetPreferences( 'MemoPref', { First => 'one', Second => 'two' } );
ok $ok, "set preferences: $msg";

note "preference content is deserialized once per request";
{
    my $first  = $user->Preferences('MemoPref');
    my $second = $user->Preferences('MemoPref');

    ok ref $first eq 'HASH', 'got a hashref of preferences';
    is $first->{First}, 'one', 'preference value is correct';
    is refaddr($first), refaddr($second), 'the same structure was returned twice';
}

note "defaults are merged into a copy, not into the cached content";
{
    my $with_defaults = $user->Preferences( 'MemoPref', { Third => 'three' } );
    is $with_defaults->{Third}, 'three', 'the default was applied';

    my $without_defaults = $user->Preferences('MemoPref');
    ok !exists $without_defaults->{Third}, 'the default did not stick to the cached content';

    my $again = $user->Preferences( 'MemoPref', { Fourth => 'four' } );
    ok !exists $again->{Third}, 'an earlier default does not leak into a later merge';
    is $again->{Fourth}, 'four', 'the later default is applied';
}

note "SetPreferences invalidates the memo";
{
    ( $ok, $msg ) = $user->SetPreferences( 'MemoPref', { First => 'updated' } );
    ok $ok, "updated preferences: $msg";

    my $after = $user->Preferences('MemoPref');
    is $after->{First}, 'updated', 'the new value is visible';
    ok !exists $after->{Second}, 'no stale keys from the replaced content';
}

note "the attribute object itself is memoized";
{
    my ($attr) = $user->Attributes->Named('Pref-MemoPref');
    ok $attr && $attr->Id, 'found the attribute record';
    is refaddr( $attr->Content ), refaddr( $attr->Content ),
        'two Content calls returned the same structure';

    my ( $set, $set_msg ) = $attr->SetContent( { First => 'direct' } );
    ok $set, "set content directly: $set_msg";
    is $attr->Content->{First}, 'direct', 'direct SetContent invalidated the memo';
}

done_testing();
