package OpenUrlBank;
use warnings;
use strict;
use Moose;
use Data::Dumper;
use feature 'say';
use feature 'switch';
use Admin::FileReader qw(slurp read_file file2hash file2hash_tab);
use IOL::Utils;
use IOL::LinkingOptimizer;
use Manager::Config;
use IOL::LinkChecker;

my ($timestamp) = `date +%Y%m%d%H%M%S`;
chomp ($timestamp);

has 'input_file' => (
    is  => 'rw',
    isa => 'Str',
);

##DB connection (connect on demand)
has 'db_engine' => (
    is  => 'ro',
    isa => 'IOL::Utils',
    lazy_build => 1,
);

use constant {
    ADDED       => 1,
    NOT_ADDED   => 0,
    UPDATED     => 1,
    NOT_UPDATED => 0,
    ALL         => 1,
    RANDOM      => 2,
    TARGET      => 3,
    ORDER       => 4,
    TEST_BY_ID  => 5,
};

#============================================= 
sub add_urls {
#============================================= 
    my ($this) = @_;
    
    ##Get URLs from file
    my @urls = slurp($this->input_file);
    $this->{'header'} = shift(@urls);
    $this->{'header'} =~ s/\s+$//g;
    
    ##Make sure headers are valid
    $this->validate_header();
    
    ##Update DB if URL does not exist yet
    my $added = 0;
    for my $url (@urls){
        my ($url_hash)   = $this->url2hash($url);
        ##skip when empty
        if (!$url_hash){
            next;
        }
        $added  += $this->add2db($url_hash);
    }

    ##Print the results;
    $this->print_results_add($added);
}

#============================================= 
sub update_urls_by_id {
#============================================= 
    my ($this) = @_;
    
    ##Get URLs from file
    my @urls = slurp($this->input_file);
    $this->{'header'} = shift(@urls);
    
    ##Update DB if URL does not exist
    my $updated = 0;
    for my $url (@urls){
        my ($id, $status) = split('\t', $url);
        if (($id !~ /^\d+$/) or ($status !~ /(ACTIVE|INACTIVE)/i)){
            print "Incorrect input - skipping line\n";
            next;
        }
        $updated  += $this->update_db_id($id, $status);
    }

    ##Print the results;
    $this->print_results_update($updated);
}

#============================================= 
sub update_urls_by_target {
#============================================= 
    my ($this,$target,$status) = @_;
    
    ##Get target IDs
    my $sql;
    ##If target ends with '_', search with 'like'
    if ($target =~ /\_$/){
        $sql = "select open_url_id from OPEN_URL_BANK where target like '$target%'";
    }
    else{
        $sql = "select open_url_id from OPEN_URL_BANK where target like '$target%'";
    }
    my $rs = $this->db_engine->_execute_single_query( $sql);
    if (!$rs){
        die("SQL query has failed");
    }

    #Update URL status according to ids
    my $updated = 0;
    while (my $line_hash = $rs->fetchrow_hashref()){
        my ($id) = $line_hash->{'open_url_id'};
        $updated  += $this->update_db_id($id,$status);
    }

    #Print the results;
    $this->print_results_update($updated);
}

#============================================= 
sub update_targets {
#============================================= 
    my ($this) = @_;
    my @targets = slurp($this->input_file);
    my $updated = 0;

    ##Update all "old_targets' to 'new_targets' 
    for my $target_line (@targets){
        my ($target_old, $target_new) = split(/\t/, $target_line);
        $updated += $this->update_db_targets($target_old, $target_new);
    }
    
    #Print the results;
    $this->print_results_update($updated);
}

#============================================= 
sub update_history_table {
#============================================= 
    my ($this,$date) = @_;
    
    ##Get URLs from file
    my @urls = slurp($this->input_file);
    $this->{'header'} = shift(@urls);
    $this->{'header'} =~ s/\s+$//g;
    
    my ($sql, $rs);
    for my $url (@urls){
        my ($url_hash)   = $this->url2hash($url);

        ##Get the values from the hash
        my $openurl_id   = $url_hash->{'openurl id'};
        my $status       = "'".$url_hash->{'status'}."'";
        if ($status =~ /AMBIGUOUS/){
            $status = "'AMBIGUOUS'";
        }
        my $info         = "''";
        if ($url_hash->{'info'}){
            $url_hash->{'info'} =~ s/'/\\'/g;
            $info = "'".$url_hash->{'info'}."'";
        }

        ##Execute the SQL query
        $sql = qq{
        insert into LINKING_TEST_HISTORY
        (OPEN_URL_ID,DATE_TESTED,STATUS,INFO)
        VALUES ($openurl_id,$date,$status,$info)
        };
        
        $rs = $this->db_engine->_execute_single_update($sql);
    }
}

#============================================= 
sub update_misc_from_file {
#============================================= 
    my ($this) = @_;
    
    #Get URLs from file
    my @urls = slurp($this->input_file);
    $this->{'header'} = shift(@urls);
    $this->{'header'} =~ s/\s+$//g;
    
    #Remove existing failed URLs
    $this->remove_existing();

    for my $url (@urls){
        my ($url_hash)   = $this->url2hash($url);
        
        ##Don't update URLs with status PASS
        my $status       = $url_hash->{'status'};
        if ($status eq 'PASS'){
            next;
        }
        #Get the values from the hash
        my ($op_id,$object_id,$info) = get_values_from_hash($url_hash);
        
        #Execute the SQL query
        my $sql = qq{
        insert into MISC_FAILED_URLS
        (OBJECT_ID,OP_ID,INFO)
        VALUES ($object_id,$op_id,$info)
        };
        my $rs = $this->db_engine->_execute_single_update($sql);
    }
}

#============================================= 
sub remove_misc_from_db {
#============================================= 
    my ($this, $email) = @_;
    my $sql = "select op_id from MISC_FAILED_URLS";
    my $rs = $this->db_engine->_execute_single_query($sql);
    my $count = 0;
    my $iol = IOL::LinkChecker->new();
    while (my ($op_id) = $rs->fetchrow_array()){
        $iol->remove_op($op_id);
        $count++;
    }
    
    ##Send emails to multiple recipients 
    my @emails = split(/;/, $email);
    for my $email (@emails){
        $this->send_mail($count, $email);
    }
}

#============================================= 
sub send_mail {
#============================================= 
    my ($this, $count, $email) = @_;
    my $msg = MIME::Lite->new(
        From    => 'clean_miscellaneous@exlibrisgroup.com',
        To      => $email,
        Subject => 'Withdrawn portfolios from Miscellaneous Free Ejournals',
        Type    =>'multipart/mixed'
    );

    ##Add the text message part:
    my $message = "$count portfolios have been withdrawn from the DB\n".
                  "\nPlease commit the changes by Wednesday\n";
                  
    $msg->attach(
        Type     =>'TEXT',
        Data     => $message,
    );

    $msg->send;
}

#============================================= 
sub update_daily_tests {
#============================================= 
    my ($this,$date,$source) = @_;
    
    #Get URLs from file
    my @urls = slurp($this->input_file);
    $this->{'header'} = shift(@urls);
    $this->{'header'} =~ s/\s+$//g;

    my ($total, $pass, $fail) = (0,0,0);
    for my $url (@urls){
        my ($url_hash)   = $this->url2hash($url);
        
        ##Get count and fail pass
        my $status       = $url_hash->{'status'};
        if ($status eq 'PASS'){
            $pass++;
        }
        else{
            $fail++;
        }
        $total++;
    }


    ##Execute the SQL query
    my $sql = qq{
    insert into DAILY_TESTS
    (DATE_TESTED,TOTAL_TESTED,TOTAL_PASSED,TOTAL_FAILED,SOURCE)
    VALUES ($date,$total,$pass,$fail,'$source')
    };

    my $rs = $this->db_engine->_execute_single_update($sql);
}

#============================================= 
sub remove_existing{
#============================================= 
    my ($this) = @_;
    my $sql = 'DELETE FROM MISC_FAILED_URLS';
    my $rs = $this->db_engine->_execute_single_update($sql);
}

#============================================= 
sub get_values_from_hash{
#============================================= 
    my ($url_hash) = @_;
    
    ##Remove leading spaces
    my $op_id   = $url_hash->{'portfolio id'};
    $op_id =~ s/ //g;
    my $object_id = $url_hash->{'object id'};
    $object_id =~ s/ //g;
    
    my $info;
    ##Quote info for DB  
    if ($url_hash->{'info'}){
        $url_hash->{'info'} =~ s/'/\\'/g;
        $info = "'".$url_hash->{'info'}."'";
    }
    return ($op_id,$object_id,$info)
}

#============================================= 
sub check_bank {
#============================================= 
    my ($this,$filter_type, $filter_value,$email,$l_timestamp) = @_;
    
    if ($l_timestamp){
        $timestamp = $l_timestamp;
    }

    my $sql = "";
    given ($filter_type){
        when (ALL){
            ($sql) = $this->create_sql_all();
        }
        when (RANDOM){
            ($sql) = $this->create_sql_random($filter_value);
        }
        when (TARGET){
            ($sql) = $this->create_sql_target($filter_value);
        }
        when (ORDER){
            ($sql) = $this->create_sql_order($filter_value);
        }
        when (TEST_BY_ID){
            ($sql) = $this->create_sql_id($filter_value);
        }
    }

    ##Perform the SQL query
    my $rs  = $this->db_engine->_execute_single_query($sql);
    if (!$rs){
        say $this->db_engine->get_error();
    }
    ##Create file for the linking optimizer (link checker)
    my ($link_checker_file) = $this->create_lc_file($rs);

    ##Run linking optimizer on input file
    my $link_optimizer = IOL::LinkingOptimizer->new();
    $link_optimizer->check_links({open_url_file=>$link_checker_file,email_to=>$email,timestamp=>$timestamp,bank_mode=>1});

}

#============================================= 
sub create_lc_file {
#============================================= 
    my ($this,$rs) = @_;
    my $input_dir = $this->create_input_dir();
    my $input_file = "$input_dir/bank_input.txt";
    
    open OUT, ">", $input_file;
    print OUT "OpenURL ID\tOpenURL Sent\ttarget_name\ttarget order\ttarget service type\tlevel\n";
    
    while (my $line_hash = $rs->fetchrow_hashref()){
    
        my $open_url = $line_hash->{'open_url_base'}.'?'.$line_hash->{'open_url_params'};
        print OUT "$line_hash->{'open_url_id'}\t$open_url\t$line_hash->{'target'}\t";
        print OUT "$line_hash->{'target_order'}\t$line_hash->{'service_type'}\t$line_hash->{'level'}\n";
    }
    close OUT;

    return $input_file;
}

#==========================================================================
sub create_input_dir {
#==========================================================================
    my ($this) = @_;
    
    foreach my $dir ( "$ENV{ET}/logs", "$ENV{ET}/logs/bank",
        "$ENV{ET}/logs/bank/$timestamp" )
    {
        unless ( -e $dir ) {
            mkdir $dir, 0751
              or die "Unable to create output directory '$dir': $!";
        }
    }
    return ("$ENV{ET}/logs/bank/$timestamp");
}


#============================================= 
sub validate_header {
#============================================= 
    my ($this) = @_;
    my @header_fields = split (/\t/, $this->{'header'});
    ##Valid headers
    my $valid_headers = {open_url=>1,target=>1,target_order=>1,service_type=>1,object_id=>1,vendor=>1,level=>1,source=>1};
    
    ##Check each header is valid
    for my $fld (@header_fields){
        if (!$valid_headers->{$fld}){
            print "You have entered an invalid header field: '$fld'\n";
            print "Valid headers are: 'open_url','target','target_order','service_type','object_id','vendor'\n";
            exit(0);
        }
    }
}

#============================================= 
sub url2hash {
#============================================= 
    my ($this, $line) = @_;
    $line =~ s/\n//g;
    
    ##Split header fields and line fields
    my @header_fields = split (/\t/, $this->{'header'});
    my @line_fields   = split (/\t/, $line);

    if (!scalar(@line_fields)){
        #warn "Line is empty\n";
        return ("");
    }
    
    ##Fill the hash
    my $hash = {};
    my $i = 0;    
    for my $fld (@header_fields){
        ##Special fix for open URL
        if ($fld eq 'open_url'){
            my $open_url = $line_fields[$i];
            
            ##split between base URL and params. Sort params for better matching
            my ($open_url_base, $open_url_params) = $this->get_params($open_url);
            $hash->{'open_url_params'} = $open_url_params;
            $hash->{'open_url_base'}  = $open_url_base;
            $i++;
            next;
        }
        $hash->{lc($fld)} = $line_fields[$i];
        $i++;
    }
    
    return $hash;
}


#============================================= 
sub parse_config_file {
#============================================= 
    my ($this, $conf_file) = @_;
    
    my $config = Manager::Config->new(file => $conf_file)
        or die("Unable to read config file at '$conf_file'");

    my $config_hash  = $config->getHashSection('MAIN');
    for my $key (keys %$config_hash){
        $this->{$key} = $config_hash->{$key};
    }

}

#============================================= 
sub add2db {
#============================================= 
    my ($this, $db_hash) = @_;

    ##Check if Open URL already exists for target;
    my $exists = $this->find_match($db_hash);

    ##Update if it doesn't exist
    if (!$exists){
        my $sql = $this->create_dynamic_sql($db_hash);
        my $rs = $this->db_engine->_execute_single_update($sql);
        if ( !$rs ) {
            say "error = ".$this->db_engine->error();
            return NOT_ADDED;
        }
        return ADDED;
    }
    else{
        return NOT_ADDED;
    }
}

#============================================= 
sub update_db_id {
#============================================= 
    my ($this,$id,$status) = @_;

    ##Check if update is necessary
    my $sql = qq{
    select status from OPEN_URL_BANK 
    where open_url_id = $id
    and status='$status'
    };

    my $rs = $this->db_engine->_execute_single_query( $sql);
    if (!$rs){
        die("SQL query has failed");
    }
    
    ##Don't update if status already exists
    my $count = $rs->get_count();
    if ($count){
        return NOT_UPDATED;
    }

    ##update URL
    $sql = qq{
    update OPEN_URL_BANK 
    set status = '$status'
    where open_url_id = $id
    };
 
    $rs = $this->db_engine->_execute_single_update( $sql);
    if ( !$rs ) {
        die("SQL query has failed");
    }
    return UPDATED;
}

#============================================= 
sub update_db_targets {
#============================================= 
    my ($this,$target_old,$target_new) = @_;

    ##Check if update is necessary
    my $sql = qq{
    select * from OPEN_URL_BANK 
    where target = '$target_old'
    };

    my $rs = $this->db_engine->_execute_single_query( $sql);
    if (!$rs){
        die("SQL query has failed");
    }
    
    ##Update only if old target exists
    my $count = $rs->get_count();
    if (!$count){
        return NOT_UPDATED;
    }

    ##update URL
    $sql = qq{
    update OPEN_URL_BANK 
    set target = '$target_new'
    where target = '$target_old'
    };
 
    $rs = $this->db_engine->_execute_single_update( $sql);
    if ( !$rs ) {
        die("SQL query has failed");
    }
    return $count;
}

#============================================= 
sub find_match{
#============================================= 
    my ($this, $db_hash) = @_;
    my $params = $db_hash->{open_url_params};
    my $target   = $db_hash->{target};

    ##Check for match with open URL and Target
    my $sql = qq{
    select * from OPEN_URL_BANK
    where open_url_params = '$params'
    and target = '$target'
    };

    my $rs = $this->db_engine->_execute_single_query( $sql);
    if (!$rs){
        die("SQL query has failed");
    }
    return $rs->get_count();
}

#============================================= 
sub create_dynamic_sql {
#============================================= 
    my ($this, $args) = @_;

    my $values = "";
    my @columns;
    for my $key (keys %{$args}){
        push (@columns, $key);
        if ($args->{$key}){
            $values .= "'$args->{$key}',";
        }
        else{
            $values .= "'',";
        }
    }
    chop($values);

    my $columns = join (",", @columns);

    my $sql = qq{
        insert into OPEN_URL_BANK ($columns)
        VALUES ($values)
    };

    return ($sql);
}

#============================================= 
sub get_params {
#============================================= 
    my ($this, $open_url) = @_;
    my ($hostname, $params) = split (/\?/, $open_url);
    my @params = split (/\&/, $params);

    ##Sort the params for better matching
    my $sorted_params = join ("&", sort(@params));
    
    ##remove ctx_tim because it will always be different
    $sorted_params =~ s/ctx_tim=.*?\&.//g;

    return ($hostname, $sorted_params);
}

#============================================= 
sub print_results_add {
#============================================= 
    my ($this, $added) = @_;
    given ($added){
        when ('0'){
            say "No URLs have been added to the bank";
        }
        when ('1'){
            say "1 URL has been added to the bank";
        }
        default {
            say "$added URLs have been added to the bank";
        }
    }
}

#============================================= 
sub print_results_update{
#============================================= 
    my ($this, $updated) = @_;
    print "\n";
    given ($updated){
        when ('0'){
            say "No URLs have been updated";
        }
        when ('1'){
            say "1 URL has been updated";
        }
        default {
            say "$updated URLs have been updated";
        }
    }
}

#============================================= 
sub create_sql_all {
#============================================= 
    my ($this) = @_;
    my $sql = qq{
    select open_url_id,open_url_base,open_url_params,target,target_order,service_type,level
    from OPEN_URL_BANK
    where status = 'Active'
    };
    return $sql;
}

#============================================= 
sub create_sql_random {
#============================================= 
    my ($this,$rand_num) = @_;
    my $sql = qq{
    select open_url_id,open_url_base,open_url_params,target,target_order,service_type,level
    from OPEN_URL_BANK
    where status = 'Active'
    order by RAND()
    limit $rand_num
    };

    return $sql;
}

#============================================= 
sub create_sql_target {
#============================================= 
    my ($this, $target) = @_;
    my $sql = qq{
    select open_url_id,open_url_base,open_url_params,target,target_order,service_type,level
    from OPEN_URL_BANK
    where status = 'Active'
    and target = '$target'
    };
    return $sql;
}

#============================================= 
sub create_sql_order {
#============================================= 
    my ($this, $target_order) = @_;
    my $sql = qq{
    select open_url_id,open_url_base,open_url_params,target,target_order,service_type,level
    from OPEN_URL_BANK
    where status = 'Active'
    and target_order <= $target_order
    };
    return $sql;
}

#============================================= 
sub create_sql_id {
#============================================= 
    my ($this, $input_file) = @_;

    my @ids = slurp($input_file);
    my $ids = join(",", @ids);
    my $sql = qq{
    select open_url_id,open_url_base,open_url_params,target,target_order,service_type,level
    from OPEN_URL_BANK
    where status = 'Active'
    and open_url_id in ($ids)
    };
    return $sql;
}

#============================================= 
##Moose Builder for db connection engine
sub _build_db_engine{
#============================================= 
    my ($this) = @_;

    ##Get data from conf file
    my $conf_file = "$ENV{ET}/config/open_url_bank.config";
    $this->parse_config_file($conf_file);
    
    ##Params for DB connection
    my $db_user = $this->{'db_user'};
    my $db_pass = $this->{'db_pass'};
    my $db      = $this->{'database'};
    my $host    = $this->{'host'};
    my $port    = $this->{'port'};
    my $dsn = "DBI:mysql:database=$db;host=$host;port=$port";
   
    ##Connect to DB
    my $dbh =  DBI->connect($dsn, $db_user, $db_pass);
    if (!$dbh){
        die "Couldn't connect to database";
    }
    ##Create DB engine
    my $master_dbengine = IOL::Utils->new(undef,$dbh);
    return $master_dbengine;
}

#============================================= 
sub get_date{
#============================================= 
    my ($second, $minute, $hour,,$dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = localtime();
    my $year = 1900 + $yearOffset;
    $month++;
    my $date = "$year-$month-$dayOfMonth";

    return ($date);
}

1;

