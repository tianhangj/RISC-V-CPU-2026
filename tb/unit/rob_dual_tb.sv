`timescale 1ns/1ps
module rob_dual_tb;
    localparam integer PW=6, RB=9;
    reg clock=0;
    always #5 clock=~clock;
    reg reset=1, squash_valid=0, disp_fire=0, st_done_valid=0;
    reg [1:0] squash_tag=0, disp_count=1, done_valid=0;
    reg [3:0] done_tag=0;
    reg [2*RB-1:0] disp_rob=0;
    wire [2:0] rob_free;
    wire [1:0] rob_head, rob_tail, reg_commit_valid;
    wire [2*PW-1:0] reg_commit_payload;
    wire st_start_valid, st_start_id;
    rob #(.DISPATCH_WIDTH(2), .ROB_DEPTH(4), .PRF_SIZE(40), .SQ_DEPTH(2)) dut (
        .clock, .reset, .squash_valid, .squash_tag,
        .disp_fire, .disp_count, .disp_rob, .done_valid, .done_tag,
        .rob_free, .rob_tail, .rob_head, .reg_commit_valid, .reg_commit_payload,
        .st_start_valid, .st_start_id, .st_done_valid);
    task tick;
        begin @(posedge clock); #1; end
    endtask
    task allocate(input [1:0] count, input [PW-1:0] old0, old1);
        begin
            @(negedge clock); disp_count=count; disp_fire=1;
            disp_rob={{old1,2'd0,1'b0},{old0,2'd0,1'b0}};
            tick; @(negedge clock); disp_fire=0;
        end
    endtask
    task complete_pair(input [1:0] tag0, tag1);
        begin
            @(negedge clock); done_valid=3; done_tag={tag1,tag0};
            tick; @(negedge clock); done_valid=0;
        end
    endtask
    initial begin
        tick; @(negedge clock); reset=0;
        allocate(2,5,6);
        if (rob_tail!=2 || rob_free!=2) $fatal(1,"two-slot allocation count");
        complete_pair(0,1);
        if (reg_commit_valid!=3 || reg_commit_payload!={6'd6,6'd5})
            $fatal(1,"both banks must retire in program order");
        tick;
        allocate(1,7,0);
        complete_pair(2,2); tick;
        if (rob_tail!=3 || rob_head!=3 || rob_free!=4) $fatal(1,"single allocation at even tail");
        allocate(2,8,9); // tail=3: lane 1 wraps into tag 0 and the other bank
        if (rob_tail!=1 || rob_free!=2) $fatal(1,"two-slot tail wrap");
        complete_pair(3,0);
        if (reg_commit_valid!=3 || reg_commit_payload!={6'd9,6'd8})
            $fatal(1,"metadata order across ROB wrap");
        tick;
        allocate(2,10,11);
        allocate(2,12,13);
        @(negedge clock); squash_valid=1; squash_tag=2;
        tick; @(negedge clock); squash_valid=0;
        if (rob_tail!=3 || rob_free!=2) $fatal(1,"squash must keep the ordered prefix");
        complete_pair(1,2);
        if (reg_commit_valid!=3 || reg_commit_payload!={6'd11,6'd10})
            $fatal(1,"squash preserved wrong metadata");
        tick;
        // Store metadata in bank 1 authorizes the correct SQ entry.
        @(negedge clock); disp_count=2; disp_fire=1;
        disp_rob={{6'd14,2'd0,1'b0},{6'd0,2'd3,1'b1}};
        tick; @(negedge clock); disp_fire=0;
        complete_pair(3,0);
        if ((!st_start_valid && !dut.head_store_started) || !st_start_id || dut.retire_count!=0)
            $fatal(1,"head Store authorization from banked metadata");
        st_done_valid=1; #1;
        if (dut.retire_count!=2 || reg_commit_valid!=2 || reg_commit_payload[PW +: PW]!=14)
            $fatal(1,"Store completion and following ordinary retirement");
        tick;
        if (rob_free!=4) $fatal(1,"Store retirement count");
        $display("PASS rob_dual: banked metadata tail wrap squash Store retirement");
        $finish;
    end
    initial begin #2000; $fatal(1,"timeout"); end
endmodule
