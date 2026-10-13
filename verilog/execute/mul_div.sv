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
    localparam logic [2:0] IDLE = 3'd0, DIV = 3'd1, RESULT = 3'd2, MUL_ADD = 3'd3, MUL_FINISH = 3'd4;
    logic [2:0] state;
    logic [31:0] multiplicand_q;
    logic [2:0] mul_step;
    logic [63:0] product_q;
    logic correction_a_negative, correction_b_negative;
    logic [2:0] mul_op_q;
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
    // Radix-16 unsigned multiplication: each edge adds one 32x4 partial
    // product and shifts the combined accumulator/multiplier by four bits.
    wire [35:0] partial_product=multiplicand_q*product_q[3:0];
    wire [36:0] accumulated_product={5'b0,product_q[63:32]}+{1'b0,partial_product};
    wire [63:0] next_product={accumulated_product[35:0],product_q[31:4]};
    // MUL and DIV cannot overlap in this unit. Keep the multiplier in the
    // divisor register, and reuse the multiplicand for signed high correction.
    wire [31:0] correction_a=correction_a_negative?divisor_q:32'b0;
    wire [31:0] correction_b=correction_b_negative?multiplicand_q:32'b0;
    wire [31:0] corrected_high = product_q[63:32] - correction_a - correction_b;
    wire [31:0] mul_value = (mul_op_q == 0) ? product_q[31:0] : corrected_high;
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
    wire [7:0] data_enable = {
        active && state == DIV && div_step == 6'd31,
        active && state == MUL_FINISH,
        active && state == DIV && div_step != 6'd31,
        active && state == MUL_ADD,
        accept_special, accept_div, accept_mul, accepting};
    wire [4*8-1:0] chunk_enable;
    (* keep_hierarchy, keep *) signal_fanout #(.WIDTH(8), .BRANCHES(4))
        distribute_data_enable(data_enable, chunk_enable);
    wire [63:0] initial_product = {32'b0, in_b};
    wire [RESULT_BITS-1:0] special_result = {in_tag, in_pdst, in_special_value};
    wire [RESULT_BITS-1:0] multiply_result = {tag_q, pdst_q, mul_value};
    wire [RESULT_BITS-1:0] divide_result = {tag_q, pdst_q, div_value};
    for (genvar chunk=0; chunk<4; chunk=chunk+1) begin : g_data_capture
        localparam integer BASE=chunk*16;
        localparam integer QBITS=(31-BASE>16)?16:31-BASE;
        localparam integer RBITS=(RESULT_BITS-BASE>16)?16:RESULT_BITS-BASE;
        wire [7:0] en=chunk_enable[chunk*8 +: 8];
        always @(posedge clock) begin
            if (en[1]) product_q[BASE +: 16]<=initial_product[BASE +: 16];
            else if (en[4]) product_q[BASE +: 16]<=next_product[BASE +: 16];
        end
        if (BASE<32) always @(posedge clock) begin
            if (en[0]) divisor_q[BASE +: 16]<=in_abs_b[BASE +: 16];
            if (en[1]) multiplicand_q[BASE +: 16]<=in_a[BASE +: 16];
            if (en[2]) begin
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
                    MUL_ADD: begin
                        mul_step<=mul_step+1'b1;
                        if (mul_step==3'd7) state<=MUL_FINISH;
                    end
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
                    mul_step<=0;
                    correction_a_negative <= (in_op == 1 || in_op == 2) && in_a[31];
                    correction_b_negative <= in_op == 1 && in_b[31];
                    mul_op_q <= in_op;
                    state <= MUL_ADD;
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
