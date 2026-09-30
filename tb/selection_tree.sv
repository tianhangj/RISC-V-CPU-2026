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
        .disp_valid, .disp_uop, .disp_src1_ready, .disp_src2_ready,
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

module sched_tree_case (output logic done);
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1, squash_valid = 0;
    logic [4:0] squash_tag = 0, rob_head = 5'd30;
    logic [1:0] alu_cand_valid = 0;
    logic [189:0] alu_cand_uop = 0;
    wire [1:0] alu_cand_take;
    logic mem_cand_valid = 0;
    logic [54:0] mem_cand_uop = 0;
    wire mem_cand_take;
    wire [23:0] rd_addr;
    logic [127:0] rd_data = {4{32'h12345678}};
    wire [1:0] alu_exec_valid;
    logic [1:0] alu_exec_ready = 0;
    wire [293:0] alu_exec_payload;
    wire mul_exec_valid, mem_exec_valid;
    logic mul_exec_ready = 0, mem_exec_ready = 0;
    wire [77:0] mul_exec_payload;
    wire [106:0] mem_exec_payload;

    issue_sched dut (
        .clock, .reset, .squash_valid, .squash_tag, .rob_head,
        .alu_cand_valid, .alu_cand_uop, .alu_cand_take,
        .mem_cand_valid, .mem_cand_uop, .mem_cand_take,
        .rd_addr, .rd_data, .alu_exec_valid, .alu_exec_ready,
        .alu_exec_payload, .mul_exec_valid, .mul_exec_ready,
        .mul_exec_payload, .mem_exec_valid, .mem_exec_ready,
        .mem_exec_payload
    );

    function automatic [94:0] alu_item(input [4:0] tag, input [5:0] op,
                                       input [5:0] ps1, ps2, input [31:0] id);
        alu_item = {tag, 2'd0, op, 6'd1, ps1, ps2, 32'd0, id};
    endfunction
    function automatic [54:0] mem_item(input [4:0] tag,
                                       input [5:0] ps1, ps2);
        mem_item = {tag, 3'd0, 3'd0, ps1, ps2, 32'd0};
    endfunction
    task automatic check(input [1:0] alu_take, input mem_take,
                         input [23:0] addresses);
        #1;
        if (alu_cand_take !== alu_take || mem_cand_take !== mem_take ||
            rd_addr !== addresses)
            $fatal(1, "scheduler take %b/%b addr %h expected %b/%b %h",
                   alu_cand_take, mem_cand_take, rd_addr,
                   alu_take, mem_take, addresses);
    endtask

    initial begin
        done = 0;
        @(posedge clock);
        @(negedge clock);
        reset = 0;
        alu_cand_valid = 2'b11;
        alu_cand_uop = {alu_item(5'd2, 6'd20, 6'd3, 6'd4, 32'd1),
                        alu_item(5'd2, 6'd20, 6'd1, 6'd2, 32'd0)};
        mem_cand_valid = 1;
        mem_cand_uop = mem_item(5'd2, 6'd5, 6'd6);
        check(2'b11, 0, {6'd4, 6'd3, 6'd2, 6'd1});

        mem_cand_uop = mem_item(5'd31, 6'd5, 6'd6);
        check(2'b01, 1, {6'd2, 6'd1, 6'd6, 6'd5});

        squash_valid = 1;
        squash_tag = 5'd31;
        check(2'b00, 1, {12'd0, 6'd6, 6'd5});
        squash_valid = 0;
        mem_cand_valid = 0;
        alu_cand_uop = {alu_item(5'd2, 6'd38, 6'd3, 6'd4, 32'd1),
                        alu_item(5'd31, 6'd20, 6'd1, 6'd2, 32'd0)};
        check(2'b11, 0, {6'd4, 6'd3, 6'd2, 6'd1});
        @(posedge clock);
        #1;
        if (!alu_exec_valid[0] || !mul_exec_valid ||
            alu_exec_payload[31:0] !== 32'h12345678)
            $fatal(1, "scheduler did not latch ALU and MUL payloads");
        alu_cand_valid = 2'b10;
        mem_cand_valid = 1;
        mem_cand_uop = mem_item(5'd31, 6'd5, 6'd6);
        check(2'b00, 1, {12'd0, 6'd6, 6'd5});
        @(posedge clock);
        #1;
        alu_cand_valid = 2'b01;
        check(2'b01, 0, {12'd0, 6'd2, 6'd1});
        @(posedge clock);
        #1;
        alu_cand_valid = 2'b11;
        check(2'b00, 0, 24'd0);
        done = 1;
    end
endmodule

module sched_param_case #(
    parameter integer WIDTH = 1
) (output logic done);
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic [WIDTH-1:0] alu_cand_valid = '1;
    logic [WIDTH*95-1:0] alu_cand_uop = 0;
    wire [WIDTH-1:0] alu_cand_take;
    logic mem_cand_valid = 1;
    logic [54:0] mem_cand_uop;
    wire mem_cand_take;
    wire [2*WIDTH*6-1:0] rd_addr;
    logic [2*WIDTH*32-1:0] rd_data = 0;
    wire [WIDTH-1:0] alu_exec_valid;
    wire [WIDTH*147-1:0] alu_exec_payload;
    wire mul_exec_valid, mem_exec_valid;
    wire [77:0] mul_exec_payload;
    wire [106:0] mem_exec_payload;

    issue_sched #(.ISSUE_WIDTH(WIDTH)) dut (
        .clock, .reset, .squash_valid(1'b0), .squash_tag(5'd0),
        .rob_head(5'd30), .alu_cand_valid, .alu_cand_uop,
        .alu_cand_take, .mem_cand_valid, .mem_cand_uop,
        .mem_cand_take, .rd_addr, .rd_data,
        .alu_exec_valid, .alu_exec_ready('0), .alu_exec_payload,
        .mul_exec_valid, .mul_exec_ready(1'b0), .mul_exec_payload,
        .mem_exec_valid, .mem_exec_ready(1'b0), .mem_exec_payload
    );

    initial begin
        done = 0;
        for (integer s = 0; s < WIDTH; s = s + 1)
            alu_cand_uop[s*95 +: 95] = {5'd2, 2'd0, 6'd20, 6'd1,
                                         6'(2*s+1), 6'(2*s+2), 64'd0};
        mem_cand_uop = {5'd2, 3'd0, 3'd0, 6'd61, 6'd62, 32'd0};
        @(posedge clock);
        @(negedge clock);
        reset = 0;
        #1;
        if (alu_cand_take !== {WIDTH{1'b1}} || mem_cand_take)
            $fatal(1, "width %0d tie priority failed", WIDTH);
        for (integer k = 0; k < WIDTH; k = k + 1)
            if (rd_addr[12*k +: 12] !== {6'(2*k+2), 6'(2*k+1)})
                $fatal(1, "width %0d lane %0d address failed", WIDTH, k);
        mem_cand_uop[54:50] = 5'd31;
        #1;
        if (mem_cand_take !== 1'b1 || alu_cand_take !==
            ( {WIDTH{1'b1}} >> 1 ))
            $fatal(1, "width %0d MEM priority failed", WIDTH);
        if (rd_addr[11:0] !== {6'd62, 6'd61})
            $fatal(1, "width %0d MEM address failed", WIDTH);
        done = 1;
    end
endmodule

module selection_tree_test;
    wire iq_one_done, iq_odd_done, iq_full_done;
    wire sched_done, sched_one_done, sched_three_done;
    iq_tree_case #(.DEPTH(1), .WIDTH(1)) iq_one(iq_one_done);
    iq_tree_case #(.DEPTH(5), .WIDTH(3)) iq_odd(iq_odd_done);
    iq_tree_case #(.DEPTH(16), .WIDTH(2)) iq_full(iq_full_done);
    sched_tree_case sched(sched_done);
    sched_param_case #(.WIDTH(1)) sched_one(sched_one_done);
    sched_param_case #(.WIDTH(3)) sched_three(sched_three_done);
    initial begin
        wait (iq_one_done && iq_odd_done && iq_full_done && sched_done &&
              sched_one_done && sched_three_done);
        $display("selection tree PASS");
        $finish;
    end
    initial begin
        #1000;
        $fatal(1, "selection tree timeout");
    end
endmodule
