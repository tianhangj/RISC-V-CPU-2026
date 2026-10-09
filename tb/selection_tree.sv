module iq_tree_case #(
    parameter integer DEPTH = 5,
    parameter integer WIDTH = 3
) (output logic done);
    localparam integer CW = $clog2(DEPTH+1);
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic [4:0] rob_head = 5'd30;
    logic [DEPTH-1:0] disp_valid = 0;
    logic [DEPTH*95-1:0] disp_uop = 0;
    logic [DEPTH-1:0] disp_src1_ready = '1, disp_src2_ready = '1;
    logic [WIDTH-1:0] cand_take = 0;
    wire [CW-1:0] free_count;
    wire [WIDTH-1:0] cand_valid;
    wire [WIDTH*95-1:0] cand_uop;
    logic [DEPTH-1:0] remaining;
    integer expected, best_age, age;
    integer tags [0:DEPTH-1];

    iq_core #(.ISSUE_WIDTH(WIDTH), .DISPATCH_WIDTH(DEPTH), .WB_WIDTH(1),
        .DEPTH(DEPTH), .UOP_BITS(95), .SRC2_LSB(64), .RW(5), .PW(6)) dut (
        .clock, .reset, .squash_valid(1'b0), .squash_tag(5'd0), .rob_head,
        .disp_valid, .disp_prepare(disp_valid), .disp_uop, .disp_src1_ready, .disp_src2_ready,
        .wake_valid(1'b0), .wake_pdst(6'd0), .free_count,
        .cand_valid, .cand_uop, .cand_take
    );

    initial begin
        done = 0;
        for (integer s = 0; s < DEPTH; s = s + 1) begin
            tags[s] = (s == 0) ? 31 : (s == 1 || s == 2) ? 2 : s - 1;
            disp_uop[s*95 +: 95] = {5'(tags[s]), 2'd0, 6'd20,
                                     6'd1, 6'd0, 6'd0, 32'd0, 32'(s)};
        end
        remaining = '1;
        @(posedge clock);
        @(negedge clock);
        reset = 0;
        disp_valid = '1;
        @(posedge clock);
        #1;
        disp_valid = 0;
        if (free_count != 0) $fatal(1, "IQ depth %0d did not fill", DEPTH);
        while (remaining != 0) begin
            for (integer lane = 0; lane < WIDTH; lane = lane + 1) begin
                expected = -1;
                best_age = 32;
                for (integer s = 0; s < DEPTH; s = s + 1) begin
                    age = (tags[s] - 30) & 31;
                    if (remaining[s] && age < best_age) begin
                        expected = s;
                        best_age = age;
                    end
                end
                if (expected >= 0) begin
                    if (!cand_valid[lane] || cand_uop[lane*95 +: 32] !== 32'(expected))
                        $fatal(1, "IQ depth %0d width %0d lane %0d: expected slot %0d",
                               DEPTH, WIDTH, lane, expected);
                    remaining[expected] = 0;
                    cand_take[lane] = 1;
                end else if (cand_valid[lane]) begin
                    $fatal(1, "IQ duplicated a candidate");
                end
            end
            @(posedge clock);
            #1;
            cand_take = 0;
        end
        if (free_count != CW'(DEPTH))
            $fatal(1, "IQ did not release selected slots");
        done = 1;
    end
endmodule

module sched_tree_case(output logic done);
    logic clock=0; always #5 clock=~clock;
    logic reset=1, squash_valid=0;
    logic [4:0] squash_tag=0;
    logic [0:0] cand_valid=0;
    logic [94:0] cand=0;
    wire [0:0] take, exec_valid;
    wire [11:0] rd_addr;
    logic [63:0] rd_data=0;
    logic [0:0] exec_ready=0;
    wire [146:0] exec_payload;
    wire mul_valid, mem_valid;
    issue_sched #(.ISSUE_WIDTH(1)) dut(
        .clock,.reset,.squash_valid,.squash_tag,.rob_head(5'd0),
        .alu_cand_valid(cand_valid),.alu_cand_uop(cand),.alu_cand_take(take),
        .mem_cand_valid(1'b0),.mem_cand_uop(55'd0),.mem_cand_take(),
        .rd_addr,.rd_data,.alu_exec_valid(exec_valid),.alu_exec_ready(exec_ready),.alu_exec_payload(exec_payload),
        .mul_exec_valid(mul_valid),.mul_exec_ready(1'b0),.mul_exec_payload(),
        .mem_exec_valid(mem_valid),.mem_exec_ready(1'b0),.mem_exec_payload());
    task automatic tick; @(posedge clock); #1; endtask
    task automatic put(input [4:0] tag);
        @(negedge clock);
        cand_valid=1; cand={tag,2'd0,6'd20,6'd32,6'd1,6'd2,32'd0,32'(tag)};
        #1; if (!take) $fatal(1,"IS refused free local capacity");
        tick(); @(negedge clock) cand_valid=0;
    endtask
    initial begin
        done=0; tick(); @(negedge clock) reset=0;
        put(5'd0);
        if (exec_valid) $fatal(1,"IS bypassed RR");
        if (rd_addr!=={6'd2,6'd1}) $fatal(1,"registered read addresses wrong");
        rd_data={32'd22,32'd11}; tick();
        if (!exec_valid || exec_payload[63:0]!=={32'd11,32'd22})
            $fatal(1,"RR did not sample PRF after selection");
        // Block EX and fill both IS/RR entries, younger first then older.
        put(5'd4); put(5'd1);
        @(negedge clock);
        squash_tag=2; squash_valid=1; tick();
        if (!exec_valid || exec_payload[146 -:5]!=0) $fatal(1,"older execution input lost");
        if (!dut.issue_valid[0] || dut.issue_payload[97 -:5]!=1)
            $fatal(1,"squash did not compact a surviving FIFO tail");
        @(negedge clock); squash_valid=0; exec_ready=1;
        tick();
        if (!exec_valid || exec_payload[146 -:5]!=1) $fatal(1,"surviving tail failed RR transfer");
        tick();
        if (exec_valid || mul_valid || mem_valid || dut.issue_valid)
            $fatal(1,"cancelled or consumed instruction reappeared");
        done=1;
    end
endmodule

module sched_param_case #(parameter integer WIDTH=1)(output logic done);
    logic clock=0; always #5 clock=~clock;
    logic reset=1;
    logic [WIDTH-1:0] cand_valid=0;
    logic [WIDTH*95-1:0] cand=0;
    logic mem_cand_valid=0;
    logic [54:0] mem_cand;
    wire [WIDTH-1:0] take, exec_valid;
    wire mem_take, mul_valid, mem_valid;
    wire [12*WIDTH-1:0] rd_addr;
    wire [WIDTH*147-1:0] exec_payload;
    issue_sched #(.ISSUE_WIDTH(WIDTH)) dut(
        .clock,.reset,.squash_valid(1'b0),.squash_tag(5'd0),.rob_head(5'd30),
        .alu_cand_valid(cand_valid),.alu_cand_uop(cand),.alu_cand_take(take),
        .mem_cand_valid,.mem_cand_uop(mem_cand),.mem_cand_take(mem_take),
        .rd_addr,.rd_data({2*WIDTH{32'h12345678}}),
        .alu_exec_valid(exec_valid),.alu_exec_ready({WIDTH{1'b0}}),.alu_exec_payload(exec_payload),
        .mul_exec_valid(mul_valid),.mul_exec_ready(1'b0),.mul_exec_payload(),
        .mem_exec_valid(mem_valid),.mem_exec_ready(1'b0),.mem_exec_payload());
    initial begin
        done=0;
        for(integer k=0;k<WIDTH;k=k+1)
            cand[k*95 +:95]={5'd2,2'd0,6'd20,6'd32,6'(2*k+1),6'(2*k+2),64'd0};
        mem_cand={5'd2,3'd0,3'd0,6'd61,6'd62,32'd0};
        @(posedge clock); @(negedge clock); reset=0; cand_valid='1; mem_cand_valid=1;
        #1; if(take!=={WIDTH{1'b1}} || mem_take) $fatal(1,"width %0d tie priority",WIDTH);
        mem_cand[54:50]=31;
        #1; if(!mem_take || take!==({WIDTH{1'b1}}>>1)) $fatal(1,"width %0d age wrap priority",WIDTH);
        @(posedge clock); #1; cand_valid=0; mem_cand_valid=0;
        if(exec_valid || mem_valid || mul_valid) $fatal(1,"width %0d missing IS/RR boundary",WIDTH);
        if(rd_addr[11:0]!=={6'd62,6'd61}) $fatal(1,"MEM register address mismatch");
        for(integer k=1;k<WIDTH;k=k+1)
            if(rd_addr[12*k +:12]!=={6'(2*k),6'(2*k-1)}) $fatal(1,"ALU register address mismatch");
        @(posedge clock); #1;
        if(!mem_valid || exec_valid!==({WIDTH{1'b1}}<<1)) $fatal(1,"width %0d RR routing mismatch",WIDTH);
        done=1;
    end
endmodule

module selection_tree_test;
    wire iq_one_done, iq_odd_done, iq_full_done;
    wire sched_done, sched_one_done, sched_three_done, sched_four_done;
    iq_tree_case #(.DEPTH(1), .WIDTH(1)) iq_one(iq_one_done);
    iq_tree_case #(.DEPTH(5), .WIDTH(3)) iq_odd(iq_odd_done);
    iq_tree_case #(.DEPTH(16), .WIDTH(2)) iq_full(iq_full_done);
    sched_tree_case sched(sched_done);
    sched_param_case #(.WIDTH(1)) sched_one(sched_one_done);
    sched_param_case #(.WIDTH(3)) sched_three(sched_three_done);
    sched_param_case #(.WIDTH(4)) sched_four(sched_four_done);
    initial begin
        wait (iq_one_done && iq_odd_done && iq_full_done && sched_done &&
              sched_one_done && sched_three_done && sched_four_done);
        $display("selection tree PASS");
        $finish;
    end
    initial begin
        #1000;
        $fatal(1, "selection tree timeout");
    end
endmodule
