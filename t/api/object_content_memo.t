use strict;
use warnings;

use Scalar::Util qw(refaddr);

use RT::Test tests => undef;

my $user = RT::Test->load_or_create_user(
    Name         => 'contentmemo',
    Password     => 'password',
    EmailAddress => 'contentmemo@example.com',
    Privileged   => 1,
);
ok $user && $user->id, 'loaded or created user';

for my $right (qw(LoadSavedSearch SeeOwnSavedSearch AdminOwnSavedSearch)) {
    my ( $ok, $msg ) = $user->PrincipalObj->GrantRight( Right => $right );
    ok $ok, "granted $right: $msg";
}

my $current_user = RT::CurrentUser->new($user);

my $search = RT::SavedSearch->new($current_user);
my ( $sid, $smsg ) = $search->Create(
    PrincipalId => $user->Id,
    Type        => 'Ticket',
    Name        => 'content memo search',
    Content     => {
        Query  => "Queue = 'General'",
        Format => '__id__',
    },
);
ok $sid, "created saved search: $smsg";

# Without a memo every call builds a new RT::ObjectContent record and decodes a
# new structure, so identity is the signal that the read happened once.
note "Content and ContentObj are computed once per object";
{
    my $loaded = RT::SavedSearch->new($current_user);
    $loaded->Load($sid);
    is $loaded->Id, $sid, 'loaded the saved search';

    my $content_obj_1 = $loaded->ContentObj;
    my $content_obj_2 = $loaded->ContentObj;
    ok $content_obj_1 && $content_obj_1->Id, 'ContentObj returned the record';
    is refaddr($content_obj_1), refaddr($content_obj_2),
        'ContentObj returned the same record twice';

    my $first  = $loaded->Content;
    my $second = $loaded->Content;
    is $first->{Query}, "Queue = 'General'", 'content decoded';
    is refaddr($first), refaddr($second), 'Content returned the same structure twice';
}

note "SetContent invalidates the memo on the same object";
{
    my ( $ok, $msg ) = $search->SetContent( {
        Query  => "Queue = 'Other'",
        Format => '__id__',
    } );
    ok $ok, "updated content: $msg";

    is $search->Content->{Query}, "Queue = 'Other'", 'same object sees the new content';
}

note "a freshly loaded object sees the new content";
{
    my $reloaded = RT::SavedSearch->new($current_user);
    $reloaded->Load($sid);
    is $reloaded->Content->{Query}, "Queue = 'Other'", 'no stale content across objects';
}

note "the dashboard wrapper (_SetContent) invalidates too";
{
    my $dashboard = RT::Dashboard->new( RT->SystemUser );
    my ( $did, $dmsg ) = $dashboard->Create(
        Name    => 'content memo dashboard',
        Content => { portlets => [] },
    );
    ok $did, "created dashboard: $dmsg";

    my $first  = $dashboard->Content;
    my $second = $dashboard->Content;
    is refaddr($first), refaddr($second), 'dashboard content memoized';

    my ( $ok, $msg ) = $dashboard->SetContent( { portlets => [ { id => 1 } ] } );
    ok $ok, "set dashboard content: $msg";

    my $portlets = $dashboard->Content->{portlets};
    is scalar @$portlets, 1, 'dashboard content was invalidated and re-read';
}

done_testing();
