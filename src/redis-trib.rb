#!/usr/bin/env ruby

# TODO (temporary here, we'll move this into the Github issues once
#       redis-trib initial implementation is completed).
#
# - Make sure that if the rehashing fails in the middle redis-trib will try
#   to recover.
# - When redis-trib performs a cluster check, if it detects a slot move in
#   progress it should prompt the user to continue the move from where it
#   stopped.
# - Gracefully handle Ctrl+C in move_slot to prompt the user if really stop
#   while rehashing, and performing the best cleanup possible if the user
#   forces the quit.
# - When doing "fix" set a global Fix to true, and prompt the user to
#   fix the problem if automatically fixable every time there is something
#   to fix. For instance:
#   1) If there is a node that pretend to receive a slot, or to migrate a
#      slot, but has no entries in that slot, fix it.
#   2) If there is a node having keys in slots that are not owned by it
#      fix this condition moving the entries in the same node.
#   3) Perform more possibly slow tests about the state of the cluster.
#   4) When aborted slot migration is detected, fix it.

require 'rubygems'
require 'redis'

ClusterHashSlots = 16384

def xputs(s)
    printf s
    STDOUT.flush
end

class ClusterNode
    def initialize(addr)
        s = addr.split(":")
        if s.length != 2
            puts "Invalid node name #{addr}"
            exit 1
        end
        @r = nil
        @info = {}
        @info[:host] = s[0]
        @info[:port] = s[1]
        @info[:slots] = {}
        @dirty = false # True if we need to flush slots info into node.
        @friends = []
    end

    def friends
        @friends
    end

    def slots 
        @info[:slots]
    end

    def to_s
        "#{@info[:host]}:#{@info[:port]}"
    end

    def connect(o={})
        return if @r
        xputs "Connecting to node #{self}: "
        begin
            @r = Redis.new(:host => @info[:host], :port => @info[:port])
            @r.ping
        rescue
            puts "ERROR"
            puts "Sorry, can't connect to node #{self}"
            exit 1 if o[:abort]
            @r = nil
        end
        puts "OK"
    end

    def assert_cluster
        info = @r.info
        if !info["cluster_enabled"] || info["cluster_enabled"].to_i == 0
            puts "Error: Node #{self} is not configured as a cluster node."
            exit 1
        end
    end

    def assert_empty
        if !(@r.cluster("info").split("\r\n").index("cluster_known_nodes:1")) ||
            (@r.info['db0'])
            puts "Error: Node #{self} is not empty. Either the node already knows other nodes (check with CLUSTER NODES) or contains some key in database 0."
            exit 1
        end
    end

    def load_info(o={})
        self.connect
        nodes = @r.cluster("nodes").split("\n")
        nodes.each{|n|
            # name addr flags role ping_sent ping_recv link_status slots
            split = n.split
            name,addr,flags,role,ping_sent,ping_recv,link_status = split[0..6]
            slots = split[7..-1]
            info = {
                :name => name,
                :addr => addr,
                :flags => flags.split(","),
                :role => role,
                :ping_sent => ping_sent.to_i,
                :ping_recv => ping_recv.to_i,
                :link_status => link_status
            }
            if info[:flags].index("myself")
                @info = @info.merge(info)
                @info[:slots] = {}
                slots.each{|s|
                    if s[0..0] == '['
                        # Fixme: for now skipping migration entries
                    elsif s.index("-")
                        start,stop = s.split("-")
                        self.add_slots((start.to_i)..(stop.to_i))
                    else
                        self.add_slots((s.to_i)..(s.to_i))
                    end
                } if slots
                @dirty = false
                @r.cluster("info").split("\n").each{|e|    
                    k,v=e.split(":")
                    k = k.to_sym
                    v.chop!
                    if k != :cluster_state
                        @info[k] = v.to_i
                    else
                        @info[k] = v
                    end
                }
            elsif o[:getfriends]
                @friends << info
            end
        }
    end

    def add_slots(slots)
        slots.each{|s|
            @info[:slots][s] = :new
        }
        @dirty = true
    end

    def flush_node_config
        return if !@dirty
        new = []
        @info[:slots].each{|s,val|
            if val == :new
                new << s
                @info[:slots][s] = true
            end
        }
        @r.cluster("addslots",*new)
        @dirty = false
    end

    def info_string
        # We want to display the hash slots assigned to this node
        # as ranges, like in: "1-5,8-9,20-25,30"
        #
        # Note: this could be easily written without side effects,
        # we use 'slots' just to split the computation into steps.
        
        # First step: we want an increasing array of integers
        # for instance: [1,2,3,4,5,8,9,20,21,22,23,24,25,30]
        slots = @info[:slots].keys.sort

        # As we want to aggregate adjacent slots we convert all the
        # slot integers into ranges (with just one element)
        # So we have something like [1..1,2..2, ... and so forth.
        slots.map!{|x| x..x}

        # Finally we group ranges with adjacent elements.
        slots = slots.reduce([]) {|a,b|
            if !a.empty? && b.first == (a[-1].last)+1
                a[0..-2] + [(a[-1].first)..(b.last)]
            else
                a + [b]
            end
        }

        # Now our task is easy, we just convert ranges with just one
        # element into a number, and a real range into a start-end format.
        # Finally we join the array using the comma as separator.
        slots = slots.map{|x|
            x.count == 1 ? x.first.to_s : "#{x.first}-#{x.last}"
        }.join(",")

        "[#{@info[:cluster_state].upcase}] #{self.info[:name]} #{self.to_s} slots:#{slots} (#{self.slots.length} slots)"
    end

    # Return a single string representing nodes and associated slots.
    # TODO: remove slaves from config when slaves will be handled
    # by Redis Cluster.
    def get_config_signature
        config = []
        @r.cluster("nodes").each_line{|l|
            s = l.split
            slots = s[7..-1].select {|x| x[0..0] != "["}
            config << s[0]+":"+(slots.sort.join(","))
        }
        config.sort.join("|")
    end

    def info
        @info
    end
    
    def is_dirty?
        @dirty
    end

    def r
        @r
    end
end

class RedisTrib
    def initialize
        @nodes = []
        @fix = false
        @errors = []
    end

    def check_arity(req_args, num_args)
        if ((req_args > 0 and num_args != req_args) ||
           (req_args < 0 and num_args < req_args.abs))
           puts "Wrong number of arguments for specified sub command"
           exit 1
        end
    end

    def add_node(node)
        @nodes << node
    end

    def get_node_by_name(name)
        @nodes.each{|n|
            return n if n.info[:name] == name.downcase
        }
        return nil
    end

    def check_cluster
        puts "Performing Cluster Check (using node #{@nodes[0]})"
        show_nodes
        check_config_consistency
        check_slots_coverage
    end

    # Merge slots of every known node. If the resulting slots are equal
    # to ClusterHashSlots, then all slots are served.
    def covered_slots
        slots = {}
        @nodes.each{|n|
            slots = slots.merge(n.slots)
        }
        slots
    end

    def check_slots_coverage
        slots = covered_slots
        if slots.length == ClusterHashSlots
            puts "[OK] All #{ClusterHashSlots} slots covered."
        else
            @errors <<
                "[ERR] Not all #{ClusterHashSlots} slots are covered by nodes."
            puts @errors[-1]
            fix_slots_coverage if @fix
        end
    end

    def nodes_with_keys_in_slot(slot)
        nodes = []
        @nodes.each{|n|
            nodes << n if n.r.cluster("getkeysinslot",slot,1).length > 0
        }
        nodes
    end

    def fix_slots_coverage
        not_covered = (0...ClusterHashSlots).to_a - covered_slots.keys
        puts "\nFixing slots coverage..."
        puts "List of not covered slots: " + not_covered.join(",")

        # For every slot, take action depending on the actual condition:
        # 1) No node has keys for this slot.
        # 2) A single node has keys for this slot.
        # 3) Multiple nodes have keys for this slot.
        slots = {}
        not_covered.each{|slot|
            nodes = nodes_with_keys_in_slot(slot)
            slots[slot] = nodes
            puts "Slot #{slot} has keys in #{nodes.length} nodes: #{nodes.join}"
        }

        none = slots.select {|k,v| v.length == 0}
        single = slots.select {|k,v| v.length == 1}
        multi = slots.select {|k,v| v.length > 1}

        # Handle case "1": keys in no node.
        if none.length > 0
            puts "The folowing uncovered slots have no keys across the cluster:"
            puts none.keys.join(",")
            yes_or_die "Fix these slots by covering with a random node?"
            none.each{|slot,nodes|
                node = @nodes.sample
                puts "Covering slot #{slot} with #{node}"
                node.r.cluster("addslots",slot)
            }
        end

        # Handle case "2": keys only in one node.
        if single.length > 0
            puts "The folowing uncovered slots have keys in just one node:"
            puts single.keys.join(",")
            yes_or_die "Fix these slots by covering with those nodes?"
            single.each{|slot,nodes|
                puts "Covering slot #{slot} with #{nodes[0]}"
                nodes[0].r.cluster("addslots",slot)
            }
        end

        # Handle case "3": keys in multiple nodes.
        if multi.length > 0
            puts "The folowing uncovered slots have keys in multiple nodes:"
            puts multi.keys.join(",")
            yes_or_die "Fix these slots by moving keys into a single node?"
            multi.each{|slot,nodes|
                puts "Covering slot #{slot} moving keys to #{nodes[0]}"
                # TODO
                # 1) Set all nodes as "MIGRATING" for this slot, so that we
                # can access keys in the hash slot using ASKING.
                # 2) Move everything to node[0]
                # 3) Clear MIGRATING from nodes, and ADDSLOTS the slot to
                # node[0].
                raise "TODO: Work in progress"
            }
        end
    end

    # Check if all the nodes agree about the cluster configuration
    def check_config_consistency
        signatures=[]
        @nodes.each{|n|
            signatures << n.get_config_signature
        }
        if signatures.uniq.length != 1
            puts "[ERR] Nodes don't agree about configuration!"
        else
            puts "[OK] All nodes agree about slots configuration."
        end
    end

    def alloc_slots
        slots_per_node = ClusterHashSlots/@nodes.length
        i = 0
        @nodes.each{|n|
            first = i*slots_per_node
            last = first+slots_per_node-1
            last = ClusterHashSlots-1 if i == @nodes.length-1
            n.add_slots first..last
            i += 1
        }
    end

    def flush_nodes_config
        @nodes.each{|n|
            n.flush_node_config
        }
    end

    def show_nodes
        @nodes.each{|n|
            puts n.info_string
        }
    end

    def join_cluster
        # We use a brute force approach to make sure the node will meet
        # each other, that is, sending CLUSTER MEET messages to all the nodes
        # about the very same node.
        # Thanks to gossip this information should propagate across all the
        # cluster in a matter of seconds.
        first = false
        @nodes.each{|n|
            if !first then first = n.info; next; end # Skip the first node
            n.r.cluster("meet",first[:host],first[:port])
        }
    end

    def yes_or_die(msg)
        print "#{msg} (type 'yes' to accept): "
        STDOUT.flush
        if !(STDIN.gets.chomp.downcase == "yes")
            puts "Aborting..."
            exit 1
        end
    end

    def load_cluster_info_from_node(nodeaddr)
        node = ClusterNode.new(nodeaddr)
        node.connect(:abort => true)
        node.assert_cluster
        node.load_info(:getfriends => true)
        add_node(node)
        node.friends.each{|f|
            next if f[:flags].index("noaddr") or f[:flags].index("disconnected")
            fnode = ClusterNode.new(f[:addr])
            fnode.connect()
            fnode.load_info()
            add_node(fnode)
        }
    end

    # Given a list of source nodes return a "resharding plan"
    # with what slots to move in order to move "numslots" slots to another
    # instance.
    def compute_reshard_table(sources,numslots)
        moved = []
        # Sort from bigger to smaller instance, for two reasons:
        # 1) If we take less slots than instances it is better to start
        #    getting from the biggest instances.
        # 2) We take one slot more from the first instance in the case of not
        #    perfect divisibility. Like we have 3 nodes and need to get 10
        #    slots, we take 4 from the first, and 3 from the rest. So the
        #    biggest is always the first.
        sources = sources.sort{|a,b| b.slots.length <=> a.slots.length}
        source_tot_slots = sources.inject(0) {|sum,source|
            sum+source.slots.length
        }
        sources.each_with_index{|s,i|
            # Every node will provide a number of slots proportional to the
            # slots it has assigned.
            n = (numslots.to_f/source_tot_slots*s.slots.length)
            if i == 0
                n = n.ceil
            else
                n = n.floor
            end
            s.slots.keys.sort[(0...n)].each{|slot|
                if moved.length < numslots
                    moved << {:source => s, :slot => slot}
                end
            }
        }
        return moved
    end

    def show_reshard_table(table)
        table.each{|e|
            puts "    Moving slot #{e[:slot]} from #{e[:source].info[:name]}"
        }
    end

    def move_slot(source,target,slot,o={})
        # We start marking the slot as importing in the destination node,
        # and the slot as migrating in the target host. Note that the order of
        # the operations is important, as otherwise a client may be redirected
        # to the target node that does not yet know it is importing this slot.
        print "Moving slot #{slot} from #{source.info_string}: "; STDOUT.flush
        target.r.cluster("setslot",slot,"importing",source.info[:name])
        source.r.cluster("setslot",slot,"migrating",target.info[:name])
        # Migrate all the keys from source to target using the MIGRATE command
        while true
            keys = source.r.cluster("getkeysinslot",slot,10)
            break if keys.length == 0
            keys.each{|key|
                source.r.migrate(target.info[:host],target.info[:port],key,0,1000)
                print "." if o[:verbose]
                STDOUT.flush
            }
        end
        puts
        # Set the new node as the owner of the slot in all the known nodes.
        @nodes.each{|n|
            n.r.cluster("setslot",slot,"node",target.info[:name])
        }
    end

    # redis-trib subcommands implementations

    def check_cluster_cmd
        load_cluster_info_from_node(ARGV[1])
        check_cluster
    end

    def fix_cluster_cmd
        @fix = true
        load_cluster_info_from_node(ARGV[1])
        check_cluster
    end

    def reshard_cluster_cmd
        load_cluster_info_from_node(ARGV[1])
        check_cluster
        if @errors.length != 0
            puts "Please fix your cluster problems before resharding."
            exit 1
        end
        numslots = 0
        while numslots <= 0 or numslots > ClusterHashSlots
            print "How many slots do you want to move (from 1 to #{ClusterHashSlots})? "
            numslots = STDIN.gets.to_i
        end
        target = nil
        while not target
            print "What is the receiving node ID? "
            target = get_node_by_name(STDIN.gets.chop)
            if not target
                puts "The specified node is not known, please retry."
            end
        end
        sources = []
        puts "Please enter all the source node IDs."
        puts "  Type 'all' to use all the nodes as source nodes for the hash slots."
        puts "  Type 'done' once you entered all the source nodes IDs."
        while true
            print "Source node ##{sources.length+1}:"
            line = STDIN.gets.chop
            src = get_node_by_name(line)
            if line == "done"
                if sources.length == 0
                    puts "No source nodes given, operation aborted"
                    exit 1
                else
                    break
                end
            elsif line == "all"
                @nodes.each{|n|
                    next if n.info[:name] == target.info[:name]
                    sources << n
                }
                break
            elsif not src
                puts "The specified node is not known, please retry."
            elsif src.info[:name] == target.info[:name]
                puts "It is not possible to use the target node as source node."
            else
                sources << src
            end
        end
        puts "\nReady to move #{numslots} slots."
        puts "  Source nodes:"
        sources.each{|s| puts "    "+s.info_string}
        puts "  Destination node:"
        puts "    #{target.info_string}"
        reshard_table = compute_reshard_table(sources,numslots)
        puts "  Resharding plan:"
        show_reshard_table(reshard_table)
        print "Do you want to proceed with the proposed reshard plan (yes/no)? "
        yesno = STDIN.gets.chop
        exit(1) if (yesno != "yes")
        reshard_table.each{|e|
            move_slot(e[:source],target,e[:slot],:verbose=>true)
        }
    end

    def create_cluster_cmd
        puts "Creating cluster"
        ARGV[1..-1].each{|n|
            node = ClusterNode.new(n)
            node.connect(:abort => true)
            node.assert_cluster
            node.load_info
            node.assert_empty
            add_node(node)
        }
        puts "Performing hash slots allocation on #{@nodes.length} nodes..."
        alloc_slots
        show_nodes
        yes_or_die "Can I set the above configuration?"
        flush_nodes_config
        puts "** Nodes configuration updated"
        puts "** Sending CLUSTER MEET messages to join the cluster"
        join_cluster
        check_cluster
    end

    def addnode_cluster_cmd
        puts "Adding node #{ARGV[1]} to cluster #{ARGV[2]}"

        # Check the existing cluster
        load_cluster_info_from_node(ARGV[2])
        check_cluster

        # Add the new node
        new = ClusterNode.new(ARGV[1])
        new.connect(:abort => true)
        new.assert_cluster
        new.load_info
        new.assert_empty
        first = @nodes.first.info

        # Send CLUSTER MEET command to the new node
        puts "Send CLUSTER MEET to node #{new} to make it join the cluster."
        new.r.cluster("meet",first[:host],first[:port])
    end

    def help_cluster_cmd
        show_help
        exit 0
    end
end

COMMANDS={
    "create"  => ["create_cluster_cmd", -2, "host1:port1 ... hostN:portN"],
    "check"   => ["check_cluster_cmd", 2, "host:port"],
    "fix"     => ["fix_cluster_cmd", 2, "host:port"],
    "reshard" => ["reshard_cluster_cmd", 2, "host:port"],
    "addnode" => ["addnode_cluster_cmd", 3, "new_host:new_port existing_host:existing_port"],
    "help"    => ["help_cluster_cmd", 1, "(show this help)"]
}

def show_help
    puts "Usage: redis-trib <command> <arguments ...>"
    puts
    COMMANDS.each{|k,v|
        puts "  #{k.ljust(10)} #{v[2]}"
    }
    puts
end

# Sanity check
if ARGV.length == 0
    show_help
    exit 1
end

rt = RedisTrib.new
cmd_spec = COMMANDS[ARGV[0].downcase]
if !cmd_spec
    puts "Unknown redis-trib subcommand '#{ARGV[0]}'"
    exit 1
end
rt.check_arity(cmd_spec[1],ARGV.length)

# Dispatch
rt.send(cmd_spec[0])
