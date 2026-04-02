use strict;
use warnings;

use RT::Test::Assets tests => undef;

my $catalog = create_catalog( Name => "General" );
ok $catalog && $catalog->id, "Created catalog";

my $asset1 = create_asset( Name => "Laptop Alpha", Catalog => $catalog->id );
ok $asset1->id, "Created asset 1 (id=" . $asset1->id . ")";

my $asset2 = create_asset( Name => "Laptop Beta", Catalog => $catalog->id );
ok $asset2->id, "Created asset 2 (id=" . $asset2->id . ")";

my $asset3 = create_asset( Name => "Monitor Gamma", Catalog => $catalog->id );
ok $asset3->id, "Created asset 3 (id=" . $asset3->id . ")";

diag "SimpleSearch by Name with LIKE";
{
    my $assets = RT::Assets->new( RT->SystemUser );
    $assets->SimpleSearch( Term => "Laptop", Catalog => $catalog );
    is $assets->Count, 2, "Found 2 assets matching 'Laptop'";
}

diag "SimpleSearch by Name with no match";
{
    my $assets = RT::Assets->new( RT->SystemUser );
    $assets->SimpleSearch( Term => "Keyboard", Catalog => $catalog );
    is $assets->Count, 0, "Found 0 assets matching 'Keyboard'";
}

diag "SimpleSearch by numeric id (STARTSWITH) - the CAST bug";
{
    # This is the case that triggers CAST(main.id AS TEXT) which fails
    # on MySQL/MariaDB. The default AssetSearchFields config includes
    # id => 'STARTSWITH', so a numeric search term will go through the
    # CAST code path.
    my $id = $asset1->id;

    my $assets = RT::Assets->new( RT->SystemUser );
    $assets->SimpleSearch( Term => $id, Catalog => $catalog );
    is $assets->Count, 1, "Found asset by exact id '$id'";
    is $assets->First->id, $id, "Correct asset returned";
}

diag "SimpleSearch by partial numeric id (STARTSWITH prefix match)";
{
    # Use the first digit(s) of an asset id to test STARTSWITH behavior.
    # All our test assets should share the same leading digit since they
    # are sequential.
    my $prefix = substr( $asset1->id, 0, 1 );

    my $assets = RT::Assets->new( RT->SystemUser );
    $assets->SimpleSearch( Term => $prefix, Catalog => $catalog );
    ok $assets->Count >= 1, "Found at least 1 asset with id starting with '$prefix'";
}

diag "SimpleSearch with non-numeric term skips id field";
{
    # A non-numeric term should not attempt the id CAST path at all
    my $assets = RT::Assets->new( RT->SystemUser );
    $assets->SimpleSearch( Term => "Alpha", Catalog => $catalog );
    is $assets->Count, 1, "Found 1 asset matching 'Alpha'";
    is $assets->First->Name, "Laptop Alpha", "Correct asset returned";
}

done_testing;
