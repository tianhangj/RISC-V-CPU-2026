module mul_div #(
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 48
) (
    input logic clock, reset,
    input logic squash_valid,
    input logic [TAG_BITS-1:0] squash_tag,
    input logic [RW-1:0] rob_head,
    input logic exec_valid,
    output logic exec_ready,
    input logic [MUL_EXEC_BITS-1:0] exec_payload,
    output logic result_valid,
    input logic result_ready,
    output logic [RESULT_BITS-1:0] result_payload
);
    localparam integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer TAG_BITS = RW;
    localparam integer MUL_EXEC_BITS = TAG_BITS + 3 + PW + 64;
    localparam integer RESULT_BITS = TAG_BITS + PW + 32;
    localparam logic [2:0] IDLE = 3'd0, DIV = 3'd1, RESULT = 3'd2,
        MUL_REDUCE1 = 3'd3, MUL_REDUCE2 = 3'd4, MUL_FINISH = 3'd5;
    logic [2:0] state;
    logic [31:0] mul_a_q, mul_b_q;
    logic mul_signed_a_q, mul_signed_b_q, mul_high_q;
    logic [7*64-1:0] mul_rows_q;
    logic [2*64-1:0] mul_pair_q;
    logic [TAG_BITS-1:0] tag_q;
    logic [PW-1:0] pdst_q;
    logic rem_q;
    logic [5:0] div_step;
    logic [31:0] divisor_q, dividend_shift_q, remainder_q;
    logic [30:0] quotient_q;
    logic dividend_negative_q, quotient_negative_q;
    logic [RESULT_BITS-1:0] result_q;

    wire [TAG_BITS-1:0] in_tag = exec_payload[MUL_EXEC_BITS-1 -: TAG_BITS];
    wire [2:0] in_op = exec_payload[64+PW+2 -: 3];
    wire [PW-1:0] in_pdst = exec_payload[64+PW-1 -: PW];
    wire [31:0] in_a = exec_payload[63:32];
    wire [31:0] in_b = exec_payload[31:0];
    wire in_signed_div = (in_op == 3'd4 || in_op == 3'd6);
    wire in_special = (in_b == 0) ||
        (in_signed_div && in_a == 32'h80000000 && in_b == 32'hffffffff);
    wire [31:0] in_special_value = (in_b == 0) ?
        (in_op[1] ? in_a : 32'hffffffff) : (in_op[1] ? 32'b0 : in_a);
    wire [31:0] in_abs_a = (in_signed_div && in_a[31]) ? -in_a : in_a;
    wire [31:0] in_abs_b = (in_signed_div && in_b[31]) ? -in_b : in_b;
    // Baugh-Wooley partial products support unsigned, signed and mixed MULH.
    // Complement negative-weight bits and include their constant correction
    // in the tree, so signed high products need no extra subtractor or cycle.
    wire [33*64-1:0] mul_rows;
    for (genvar row=0; row<32; row=row+1) begin : g_partial_product
        wire [31:0] bits;
        for (genvar column=0; column<32; column=column+1) begin : g_bit
            wire negative_weight = ((column == 31) && mul_signed_a_q) ^
                ((row == 31) && mul_signed_b_q);
            assign bits[column] = (mul_a_q[column] & mul_b_q[row]) ^ negative_weight;
        end
        assign mul_rows[row*64 +: 64] = {32'b0, bits} << row;
    end
    assign mul_rows[32*64 +: 64] = {
        mul_signed_a_q | mul_signed_b_q, 30'b0,
        mul_signed_a_q & mul_signed_b_q,
        mul_signed_a_q ^ mul_signed_b_q, 31'b0};

    // Cycle 1: four Wallace 3:2 compression levels, 33 -> 22 -> 15 -> 10 -> 7.
    wire [22*64-1:0] mul_level1;
    wire [15*64-1:0] mul_level2;
    wire [10*64-1:0] mul_level3;
    wire [7*64-1:0] mul_level4;
    mul_wallace_reduce #(.ROWS(33)) reduce1(mul_rows, mul_level1);
    mul_wallace_reduce #(.ROWS(22)) reduce2(mul_level1, mul_level2);
    mul_wallace_reduce #(.ROWS(15)) reduce3(mul_level2, mul_level3);
    mul_wallace_reduce #(.ROWS(10)) reduce4(mul_level3, mul_level4);

    // Cycle 2: four more levels, 7 -> 5 -> 4 -> 3 -> 2, then register the pair.
    wire [5*64-1:0] mul_level5;
    wire [4*64-1:0] mul_level6;
    wire [3*64-1:0] mul_level7;
    wire [2*64-1:0] mul_level8;
    mul_wallace_reduce #(.ROWS(7)) reduce5(mul_rows_q, mul_level5);
    mul_wallace_reduce #(.ROWS(5)) reduce6(mul_level5, mul_level6);
    mul_wallace_reduce #(.ROWS(4)) reduce7(mul_level6, mul_level7);
    mul_wallace_reduce #(.ROWS(3)) reduce8(mul_level7, mul_level8);

    // Cycle 3: the only carry-propagating addition, followed by result capture.
    wire [63:0] mul_product = mul_pair_q[63:0] + mul_pair_q[127:64];
    wire [31:0] mul_value = mul_high_q ? mul_product[63:32] : mul_product[31:0];
    wire held_young = squash_valid &&
        ((tag_q - rob_head) > (squash_tag - rob_head));
    wire incoming_young = squash_valid &&
        ((in_tag - rob_head) > (squash_tag - rob_head));

    // One restoring-division bit is consumed on each DIV clock edge.
    wire [32:0] trial_remainder = {remainder_q, dividend_shift_q[31]};
    wire subtract = trial_remainder >= {1'b0, divisor_q};
    wire [31:0] next_remainder = subtract ?
        (trial_remainder[31:0] - divisor_q) : trial_remainder[31:0];
    wire [31:0] next_quotient = {quotient_q, subtract};
    wire [31:0] signed_quotient = quotient_negative_q ? -next_quotient : next_quotient;
    wire [31:0] signed_remainder = dividend_negative_q ?
        -next_remainder : next_remainder;
    wire [31:0] div_value = rem_q ? signed_remainder : signed_quotient;

    assign exec_ready = (state == IDLE) || (state == RESULT && result_ready);
    assign result_valid = (state == RESULT);
    assign result_payload = result_q;

    // Recovery and acceptance control only a bounded number of data muxes.
    // State and the small counters retain their original edge priority.
    wire accepting = !reset && exec_valid && exec_ready && !incoming_young;
    wire active = !reset && !(state != IDLE && held_young);
    wire accept_mul = accepting && in_op < 3'd4;
    wire accept_div = accepting && in_op >= 3'd4 && !in_special;
    wire accept_special = accepting && in_op >= 3'd4 && in_special;
    wire [8:0] data_enable = {
        active && state == MUL_REDUCE2,
        active && state == DIV && div_step == 6'd31,
        active && state == MUL_FINISH,
        active && state == DIV && div_step != 6'd31,
        active && state == MUL_REDUCE1,
        accept_special, accept_div, accept_mul, accepting};
    wire [4*9-1:0] chunk_enable;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(9), .BRANCHES(4))
        distribute_data_enable(data_enable, chunk_enable);
    wire [RESULT_BITS-1:0] special_result = {in_tag, in_pdst, in_special_value};
    wire [RESULT_BITS-1:0] multiply_result = {tag_q, pdst_q, mul_value};
    wire [RESULT_BITS-1:0] divide_result = {tag_q, pdst_q, div_value};
    for (genvar chunk=0; chunk<4; chunk=chunk+1) begin : g_data_capture
        localparam integer BASE=chunk*16;
        localparam integer QBITS=(31-BASE>16)?16:31-BASE;
        localparam integer RBITS=(RESULT_BITS-BASE>16)?16:RESULT_BITS-BASE;
        wire [8:0] en=chunk_enable[chunk*9 +: 9];
        for (genvar row=0; row<7; row=row+1) begin : g_mul_rows
            always @(posedge clock)
                if (en[4]) mul_rows_q[row*64+BASE +: 16]<=mul_level4[row*64+BASE +: 16];
        end
        for (genvar row=0; row<2; row=row+1) begin : g_mul_pair
            always @(posedge clock)
                if (en[8]) mul_pair_q[row*64+BASE +: 16]<=mul_level8[row*64+BASE +: 16];
        end
        if (BASE<32) always @(posedge clock) begin
            if (en[1]) begin
                mul_a_q[BASE +: 16]<=in_a[BASE +: 16];
                mul_b_q[BASE +: 16]<=in_b[BASE +: 16];
            end
            if (en[2]) begin
                divisor_q[BASE +: 16]<=in_abs_b[BASE +: 16];
                dividend_shift_q[BASE +: 16]<=in_abs_a[BASE +: 16];
                remainder_q[BASE +: 16]<=0;
            end else if (en[5]) begin
                dividend_shift_q[BASE +: 16]<=({dividend_shift_q[30:0],1'b0} >> BASE);
                remainder_q[BASE +: 16]<=next_remainder[BASE +: 16];
            end
        end
        if (QBITS>0) always @(posedge clock) begin
            if (en[2]) quotient_q[BASE +: QBITS]<=0;
            else if (en[5]) quotient_q[BASE +: QBITS]<=next_quotient[BASE +: QBITS];
        end
        if (RBITS>0) always @(posedge clock) begin
            if (en[3]) result_q[BASE +: RBITS]<=special_result[BASE +: RBITS];
            else if (en[6]) result_q[BASE +: RBITS]<=multiply_result[BASE +: RBITS];
            else if (en[7]) result_q[BASE +: RBITS]<=divide_result[BASE +: RBITS];
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            state <= IDLE;
        end else begin
            if (state != IDLE && held_young) begin
                state <= IDLE;
            end else begin
                case (state)
                    MUL_REDUCE1: state <= MUL_REDUCE2;
                    MUL_REDUCE2: state <= MUL_FINISH;
                    MUL_FINISH: state <= RESULT;
                    DIV: begin
                        if (div_step == 6'd31) begin
                            state <= RESULT;
                        end else begin
                            div_step <= div_step + 1'b1;
                        end
                    end
                    RESULT: if (result_ready) state <= IDLE;
                    default: state <= IDLE;
                endcase
            end
            if (exec_valid && exec_ready && !incoming_young) begin
                tag_q <= in_tag;
                pdst_q <= in_pdst;
                rem_q <= in_op[1];
                if (in_op < 3'd4) begin
                    mul_signed_a_q <= (in_op == 1 || in_op == 2);
                    mul_signed_b_q <= (in_op == 1);
                    mul_high_q <= (in_op != 0);
                    state <= MUL_REDUCE1;
                end else if (in_special) begin
                    state <= RESULT;
                end else begin
                    dividend_negative_q <= in_signed_div && in_a[31];
                    quotient_negative_q <= in_signed_div && (in_a[31] ^ in_b[31]);
                    div_step <= 0;
                    state <= DIV;
                end
            end
        end
    end
endmodule

// One Wallace layer: full adders produce a sum row and a shifted carry row.
// Carries never propagate horizontally within a compression layer.
module mul_wallace_reduce #(
    parameter integer ROWS = 3
) (
    input wire [ROWS*64-1:0] rows_in,
    output wire [((ROWS/3)*2+ROWS%3)*64-1:0] rows_out
);
    for (genvar group_no=0; group_no<ROWS/3; group_no=group_no+1) begin : g_compress
        wire [63:0] a = rows_in[(group_no*3)*64 +: 64];
        wire [63:0] b = rows_in[(group_no*3+1)*64 +: 64];
        wire [63:0] c = rows_in[(group_no*3+2)*64 +: 64];
        assign rows_out[(group_no*2)*64 +: 64] = a ^ b ^ c;
        assign rows_out[(group_no*2+1)*64 +: 64] = ((a & b) | (a & c) | (b & c)) << 1;
    end
    for (genvar tail=0; tail<ROWS%3; tail=tail+1) begin : g_tail
        assign rows_out[((ROWS/3)*2+tail)*64 +: 64] = rows_in[((ROWS/3)*3+tail)*64 +: 64];
    end
endmodule
