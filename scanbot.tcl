
namespace eval scanbot {

    package require http 2.5
    package require mysqltcl 3.0

    #####

    proc bindmsg:help { nick uhost handle text } {

        regexp {^!(.*)$} $text - text

        switch [string tolower $text] {
            "" {
                puthelp "NOTICE $nick :Commands available are:"
                puthelp "NOTICE $nick :  \037!help\037, \037!scan\037, \037!request\037, \037!add\037, \037!say\037"
                puthelp "NOTICE $nick :For more help on a command, type: \002!help \037command\037\002"
                puthelp "NOTICE $nick :Warning! - All requests are \002logged\002!"
            }
            "help" {
                puthelp "NOTICE $nick :Usage: \002!help \037command\037\002"
                puthelp "NOTICE $nick :The bots interactive help system, for help with bot commands"
            }
            "scan" {
                puthelp "NOTICE $nick :Usage: \002!scan \037x\037:\037y\037:\037z\037\002"
                puthelp "NOTICE $nick :Shows all available scans on the selected planet (note: all requests are logged)"
            }
            "request" {
                puthelp "NOTICE $nick :Usage: \002!request \037x\037:\037y\037:\037z\037 \037type\037\002"
                puthelp "NOTICE $nick :Requests a scan on the selected planet.  Valid scan types: Planet, Surface, Technology, Unit, News, Jumpgate, Military"
            }
            "add" {
                puthelp "NOTICE $nick :Usage \002!add \037scan url\037\002"
                puthelp "NOTICE $nick :Adds a scan to the bot, the scan URL must be a valid Planetarion scan which is set to visible ingame."
            }
            "say" {
                puthelp "NOTICE $nick :Usage: \002!say \037message\037\002"
                puthelp "NOTICE $nick :Forwards a message to the scan channel"
            }
            default {
                puthelp "NOTICE $nick :Try \002!help\002 for commands"
            }
        }
    }

    bind msg - !help [namespace current]::bindmsg:help

    #####

    proc bindmsg:scan { nick uhost handle text } {
        set db [sql:pconnect]

        if {[onchan $nick "#sincity"] == 0} {
            putserv "NOTICE $nick :Access denied, have you joined the private channel?"
            return
        }

        if {![regexp {^([0-9]+)[ :]([0-9]+)[ :]([0-9]+)$} $text nothing x y z]} {
            putserv "NOTICE $nick :Usage: \002!scan \037x\037:\037y\037:\037z\037\002"
            return
        }

        set res [::mysql::query $db "SELECT planetarionid,type,tick FROM scan WHERE x='$x' AND y='$y' AND z='$z' AND tick>((SELECT MAX(tick) FROM ticks)-72) ORDER BY tick DESC, id DESC"]

        set scans [::mysql::result $res rows]
        putserv "PRIVMSG #sinscan :\002---\002 \002$nick\002 requested scans on \002$x:$y:$z\002 ($scans found)"

        if {!$scans} {
            putserv "NOTICE $nick :No scans found on $x:$y:$z"
        } else {
            putserv "NOTICE $nick :Scans on $x:$y:$z:"

            ::mysql::map $res { id type tick } {
                putserv "NOTICE $nick : * PT $tick ($type) - http://game.planetarion.com/showscan.pl?scan_id=$id"
            }

            putserv "NOTICE $nick :(All of $scans [expr {$scans>1 ? "scans" : "scan"}] found)"
        }

        ::mysql::endquery $res
    }

    bind msg - !scan [namespace current]::bindmsg:scan

    #####

    proc bindmsg:add { nick uhost handle text } {
        set db [sql:pconnect]

                if {![regexp {^http://game\.planetarion\.com/showscan\.pl\?scan_id=([0-9]+)$} $text - scanid]} {
            putserv "NOTICE $nick :Invalid scan URL (must be in the form of: http://game.planetarion.com/showscan.pl?scan_id=000000001)"
            return
        }

        set url "http://game.planetarion.com/showscan.pl?scan_id=$scanid"
        set page [::http::data [::http::geturl $url]]

        if {[regexp {(Planet Scan|Surface Analysis Scan|Technology Analysis Scan|Unit Scan|News Scan|Fleet Analysis Scan|Jumpgate Probe|Military Scan) on ([1-9][0-9]{0,2}):([1-9][0-9]{0,1}):([1-9][0-9]{0,1}) in tick (\d+)} $page - type x y z tick]} {
            if {[llength $type] >= 2} {
                set type [lindex $type 0]
            }
        } else {
            putserv "NOTICE $nick :Sorry, I do not recognise $text as a public scan"
            return
        }

        set res [::mysql::query $db "SELECT COUNT(*) FROM scan WHERE planetarionid='$scanid' AND tick='$tick' AND type='$type' AND x='$x' AND y='$y' AND z='$z'"]
        set scanexists [lindex [::mysql::fetch $res] 0]
        ::mysql::endquery $res

        if {$scanexists} {
            putserv "NOTICE $nick :That scan has already been added!"
            return
        }

        ::mysql::exec $db "INSERT INTO scan (planetarionid,type,tick,x,y,z,data) VALUES ('$scanid','$type','$tick','$x','$y','$z','[::mysql::escape $db $page]')"

        set requesters ""
        set res [::mysql::query $db "SELECT nick FROM scan_request WHERE x='$x' AND y='$y' AND z='$z' AND type='$type'"]
        if {[::mysql::result $res rows]} {
            ::mysql::map $res { requester } {
                if {[onchan $nick "#sincity"]} {
                    lappend requesters $requester
                    putserv "NOTICE $requester :Received \002$type\002 scan on \002$x:$y:$z\002 - http://game.planetarion.com/showscan.pl?scan_id=$scanid"
                }
            }
        }
        ::mysql::endquery $res

        ::mysql::exec $db "DELETE FROM scan_request WHERE x='$x' AND y='$y' AND z='$z' AND type='$type'"

        set requestinfo ""

        if {[llength $requesters]} {
            set requestinfo " (notice sent to: [join $requesters ", "])"
        }

        if {![onchan $nick "#sinscan"]} {
            putserv "NOTICE $nick :Added \002$type\002 scan of \002$x:$y:$z\002 in tick \002$tick\002, thank you!"
        }

        putserv "PRIVMSG #sinscan :\002---\002 $nick has added a \002$type\002 scan of \002$x:$y:$z\002 in tick \002$tick\002$requestinfo"
    }

    bind msg - !add [namespace current]::bindmsg:add

    #####

    proc bindpub:add { nick uhost handle chan text } {
        if {[string tolower $chan] != "#sinscan"} {
            return
        }

        bindmsg:add $nick $uhost $handle $text
    }

    bind pub - !add [namespace current]::bindpub:add

    #####

    proc bindmsg:say { nick uhost handle text } {
        if {[onchan $nick "#sincity"] == 0} {
            putserv "NOTICE $nick :Access denied, have you joined the private channel?"
            return
        }

        putserv "PRIVMSG #sinscan :\0034\002<< $nick <<\002\003 $text"
        putserv "NOTICE $nick :Message forwarded to scan channel"
    }

    bind msg - !say [namespace current]::bindmsg:say

    #####

    proc bindpub:say { nick uhost handle chan text } {
        if {[string tolower $chan] != "#sinscan"} {
            return
        }

        if {![regexp {^(\S+) (.+)$} $text - target message]} {
            putserv "NOTICE $nick :Usage: \002!say \037nick\037 \037text\037\002"
            return
        }

        if {[string tolower $target] == "p"} {
            putserv "NOTICE $nick :I refuse to do that!"
            return
        }

        putserv "PRIVMSG $target :$message"
        putserv "PRIVMSG #sinscan :\0033\002>> $target >>\002\003 $message"
    }

    bind pub - !say [namespace current]::bindpub:say

    #####

    proc bindpub:list { nick uhost handle chan text } {
        set db [sql:pconnect]

        if {[string tolower $chan] != "#sinscan"} {
            return
        }

        set res [::mysql::query $db "SELECT id,type,x,y,z,nick,time FROM scan_request ORDER BY time ASC"]
        set requests [::mysql::result $res rows]

        if {$requests == 0} {
            putserv "NOTICE $nick :No scan requests found!"
        } else {
            set scantypes {Planet Surface Technology Unit News Fleet Jumpgate Military}

            ::mysql::map $res { requestid type x y z requestor time } {
                set typeid [expr [lsearch -exact $scantypes $type]+1]
                putserv "PRIVMSG #sinscan :\002---\002 Request $requestid ([timetostring $time]) - \002$requestor\002 needs a \002$type\002 scan on \002$x:$y:$z\002 - http://game.planetarion.com/waves.pl?id=$typeid&x=$x&y=$y&z=$z"
            }
        }

        ::mysql::endquery $res
    }

    bind pub - !list [namespace current]::bindpub:list

    #####

    proc bindpub:del { nick uhost handle chan text } {
        set db [sql:pconnect]

        if {[string tolower $chan] != "#sinscan"} {
            return
        }

        if {![regexp {^(\d+)$} $text - requestid]} {
            putserv "NOTICE $nick :Usage: \002!del \037id\037\002"
            return
        }

        set res [::mysql::query $db "SELECT type,x,y,z,nick FROM scan_request WHERE id='$requestid'"]
        set exists [::mysql::result $res rows]

        if {$exists == 0} {
            putserv "NOTICE $nick :No such request \002$requestid\002!"
        } else {
            set requestinfo ""

            ::mysql::map $res { type x y z requestor } {
                if {[onchan $requestor "#sincity"]} {
                    putserv "NOTICE $requestor :Your request for a \002$type\002 scan on \002$x:$y:$z\002 has been removed by a scanner!"
                    set requestinfo " (notice sent to: $requestor)"
                }
            }

            putserv "PRIVMSG #sinscan :--- Request \002$requestid\002 - \002$type\002 scan on \002$x:$y:$z\002 has been removed!$requestinfo"
        }

        ::mysql::endquery $res

        ::mysql::exec $db "DELETE FROM scan_request WHERE id='$requestid'"
    }

    bind pub - !del [namespace current]::bindpub:del

    #####

    proc bindmsg:request { nick uhost handle text } {
        set db [sql:pconnect]

        if {![regexp -nocase {^([0-9]+)[ :]([0-9]+)[ :]([0-9]+) (planet|surface|technology|unit|news|jumpgate|military)$} $text nothing x y z type]} {
            putserv "NOTICE $nick :Usage: \002!request \037x\037:\037y\037:\037z\037 \037type\037\002"
            putserv "NOTICE $nick :Valid scan types: Planet, Surface, Technology, Unit, News, Jumpgate, Military"
            return
        }

        set type [string totitle $type]
        set scantypes {Planet Surface Technology Unit News Fleet Jumpgate Military}
        set typeid [expr [lsearch -exact $scantypes $type]+1]

        set res [::mysql::query $db "SELECT COUNT(*) FROM scan_request WHERE x='$x' AND y='$y' AND z='$z' AND type='$type' AND nick='[::mysql::escape $nick]'"]
        set requested [lindex [::mysql::fetch $res] 0]
        ::mysql::endquery $res

        if {$requested == 1} {
            putserv "NOTICE $nick :You have already requested a \002$type\002 scan on \002$x:$y:$z\002, please be patient!"
            return
        }

        ::mysql::exec $db "INSERT INTO scan_request (type,x,y,z,nick,time) VALUES ('$type','$x','$y','$z','[::mysql::escape $nick]','[unixtime]')"
        set requestid [::mysql::insertid $db]

        putserv "NOTICE $nick :Request $requestid - \002$type\002 scan on \002$x:$y:$z\002"
        putserv "NOTICE #sinscan :\002---\002 Request $requestid - \002$nick\002 needs a \002$type\002 scan on \002$x:$y:$z\002 - http://game.planetarion.com/waves.pl?id=$typeid&x=$x&y=$y&z=$z"
    }

    bind msg - !request [namespace current]::bindmsg:request

    #####

    proc sql:pconnect { } {
        variable conn
        variable dblogin

        if {![info exists conn]} {
            set conn [::mysql::connect -user username -pass password -db scanbot -host 127.0.0.1]
            putlog "New MySQL Connection: $conn"
            return $conn
        } else {
            return $conn
        }
    }

    #####

    proc timetostring { timestamp } {
        set diff [expr [strftime %s]-$timestamp]

        if {$diff == 0} {
            return "now"
        }

        set days [expr $diff/86400]
        set diff [expr $diff%86400]
        set hours [expr $diff/3600]
        set diff [expr $diff%3600]
        set mins [expr $diff/60]

        set string ""

        if {$days > 0} {
            set string "${days}d ${hours}h ${mins}m"
        } elseif {$hours > 0} {
            set string "${hours}h ${mins}m"
        } else {
            set string "${mins}m"
        }

        return $string
    }

}

