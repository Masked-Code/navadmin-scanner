#!/usr/bin/env perl

use v5.18;

use Mojo::Date;
use Mojo::DOM;
use Mojo::Collection;
use Mojo::JSON qw(decode_json);
use Mojo::File;
use Mojo::UserAgent;
use Mojo::URL;

use Time::HiRes qw(usleep);

# Returns a JSON object keyed by NAVADMIN ID
sub read_navadmin_metadata
{
    my $text = eval { Mojo::File->new("navadmin_meta.json")->slurp } // "{}";
    return decode_json($text);
}

sub save_navadmin_metadata
{
    my $obj = shift;
    my $json = Mojo::JSON::encode_json($obj);

    my $file = Mojo::File->new("navadmin_meta.json");
    $file->spew($json);
}

# Reads a binary blob of HTML and pulls out list of .txt hyperlinks
sub read_navadmin_listing
{
    my $dom = Mojo::DOM->new(shift);
    my $links_ref = $dom->find('a')
        ->grep(sub { ($_->attr("href") // "") =~ qr([nN][aA][vV][^/]*\.txt\??)})
        ->map(attr => 'href')
        ->to_array;

    return @{$links_ref};
}

# Pulls the base website listing NAVADMINs and returns a promise that will
# resolve to the links to the per-year web pages
sub pull_navadmin_year_links
{
    my $ua = shift; # User agent must outlive this function

    my $cur_year = (localtime)[5] + 1900;
    my @years = '2016'.."$cur_year";

    my $BASE_URL = 'https://www.mynavyhr.navy.mil/References/Messages/NAVADMIN-';
    my $base = Mojo::URL->new($BASE_URL);

    my @urls = map { "${BASE_URL}$_/" } (@years);

    return Mojo::Promise->new->resolve(@urls);
}

my $ua = Mojo::UserAgent->new->request_timeout(10);
my @navadmin_urls;

pull_navadmin_year_links($ua)->then(sub {
    my @promises = map { $ua->get_p($_)->then(sub {
        my $tx = shift;
        my $req_url = $tx->req->url->to_abs;
        die "Failed to load $req_url: $tx->result->message"
            if $tx->result->is_error;

        # Assume that if NAVADMIN folder doesn't exist, that we've never run
        # Otherwise, that we just want updates for this year.
        my @links = read_navadmin_listing($tx->result->body);

        my $year = (localtime(time))[5] + 1900;
        if (-e '.has-run' && $req_url !~ /-$year\/$/) {
            return 1;
        } else {
            say "Loaded NAVADMINs for $req_url";

            open my $fh, '>', '.has-run';
            say $fh "NAVADMIN scanner has run";
            close $fh;
        }

        push @navadmin_urls, map { $req_url->clone->path_query($_) } (@links);
        return 1;
    })} (@_);

    return Mojo::Promise->all(@promises);
})->catch(sub {
    say "An error occurred! $_[0]";
})->wait;

my %errors;
my $metadata = read_navadmin_metadata();
mkdir ("NAVADMIN") unless -e "NAVADMIN";

say "Downloading and updating ", scalar @navadmin_urls, " NAVADMIN messages";

while (my $url = shift @navadmin_urls) {
    # Some links end in ?ver=<gibberish>, try them without ver first. But some
    # require ?ver= part too...
    my $no_ver_url = $url->clone->query({ver => undef});
    my $name = $no_ver_url->path->parts->[-1]; # filename from URL

    # The URL may have had lowercase chars, enforce filename starting with "NAV"
    substr $name, 0, 3, "NAV";
    my $shortname = (substr $name, 5, 3) . '/' . (substr $name, 3, 2);
    $name = "NAVADMIN/$name";

    my %get_opts;

    # File already exists, try to mirror instead of re-download
    if (-e $name) {
        my $ctime = (stat(_))[10];
        $get_opts{'If-Modified-Since'} = Mojo::Date->new($ctime)->to_string;
        $get_opts{'User-Agent'} = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/105.0.0.0 Safari/537.36";
    }

    my $req;
    for my $u ($no_ver_url, $url) {
        $req = eval { $ua->get($u, \%get_opts); };

        # Break if the download succeeded w/out raising an exception
        last unless ($@ || $req->result->is_error);
        say STDERR "Failed to download ver-less $u ($@), trying again w/ ver=";
    }

    my $result = $req->result;
    if ($@ || $result->is_error) {
        $errors{$url->to_string} = {
            code => $result->code,
            msg  => $result->message,
        };
        say STDERR "Failed to download $url: ", $result->code;
    } elsif (!$result->is_empty) {
        # Save file to disk
        say "Downloaded $name";
        $metadata->{$shortname} //= { };
        $metadata->{$shortname}->{dl_date} = time;
        $metadata->{$shortname}->{dl_url}  = $url->to_string;

        $result->save_to($name);
    }

    usleep (30000); # Some slowdown out of respect to the giant Sharepoint in the sky
}

while (my ($url, $err) = each %errors) {
    say "$url failed: ", $err->{code}, " ", $err->{msg};
}

save_navadmin_metadata($metadata);

say "Done";
