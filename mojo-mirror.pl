#!/usr/bin/env perl

use v5.18;

use Mojo::DOM;
use Mojo::Collection;
use Mojo::File;
use Mojo::UserAgent;

# Reads a binary blob of HTML and pulls out list of .txt hyperlinks
sub read_navadmin_listing
{
    my $dom = Mojo::DOM->new(shift);
    my $links_ref = $dom->find('a')
        ->grep(sub { ($_->attr("href") // "") =~ qr(NAV[^/]*\.txt$)})
        ->map(attr => 'href')
        ->to_array;

    return @{$links_ref};
}

# Pulls the base website listing NAVADMINs and returns a promise that will
# resolve to the links to the per-year web pages
sub pull_navadmin_year_links
{
    my $ua = shift; # User agent must outlive this function

    my $BASE_URL = 'https://www.public.navy.mil/bupers-npc/reference/messages/NAVADMINS/Pages/default.aspx';
    my $base = Mojo::URL->new($BASE_URL);

    my $promise = $ua->get_p($BASE_URL)
        ->then(sub {
            my $tx = shift;
            die ("Something broke: " . $tx->message)
                if $tx->result->is_error;
            say "Result success, looking for hyperlinks";
            my $dom = $tx->result->dom;
            my $links_ref = $dom->find('a')
                ->grep(sub { ($_->attr("href") // "") =~ qr(NAVADMIN[0-9]*\.aspx$)})
                ->map(attr => 'href')
                ->to_array;

            my @urls = map { $base->clone->path($_)->to_abs } (@{$links_ref});
            return @urls;
        });

    return $promise;
}

my $ua = Mojo::UserAgent->new;
my @year_links;

pull_navadmin_year_links($ua)->then(sub {
    my @promises = map { $ua->get_p($_)->then(sub {
        my $tx = shift;
        my $req_url = $tx->req->url->to_abs;
        die "Failed to load $req_url: $tx->result->message"
            if $tx->result->is_error;
        say "Loaded NAVADMINs for $req_url";
        my @links = read_navadmin_listing($tx->result->body);
        push @year_links, @links;
        return 1;
    })} (@_);

    return Mojo::Promise->all(@promises);
})->catch(sub {
    say "An error occurred! $_[0]";
})->wait;

say "Ended up knowing about ", scalar @year_links, " separate NAVADMINs";
