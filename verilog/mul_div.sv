module mul_div #(
    parameter integer ROB_DEPTH = 32,
    parameter integer PRF_SIZE = 64,
    parameter integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1,
    parameter integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1,
    parameter integer TAG_BITS = RW,
    parameter integer MUL_EXEC_BITS = TAG_BITS + 3 + PW + 64,
    parameter integer RESULT_BITS = TAG_BITS + PW + 32
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
    localparam logic [1:0] IDLE = 2'd0, MUL = 2'd1,
                           DIV = 2'd2, RESULT = 2'd3;
    logic [1:0] state;
    logic [TAG_BITS-1:0] tag_q;
    logic [PW-1:0] pdst_q;
    logic [2:0] op_q;
    logic [31:0] a_q, b_q;
    logic [2:0] mul_step;
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
    wire held_young = squash_valid &&
        ((tag_q - rob_head) > (squash_tag - rob_head));
    wire incoming_young = squash_valid &&
        ((in_tag - rob_head) > (squash_tag - rob_head));

    // 34 terms include the two possible high-half sign corrections.
    wire [34*64-1:0] partial_products;
    wire [31:0] neg_a = -a_q;
    wire [31:0] neg_b = -b_q;
    for (genvar i = 0; i < 32; i = i + 1) begin : g_partial
        assign partial_products[i*64 +: 64] =
            {32'b0, (a_q & {32{b_q[i]}})} << i;
    end
    assign partial_products[32*64 +: 64] =
        ((op_q == 3'd1 || op_q == 3'd2) && a_q[31]) ?
        {neg_b, 32'b0} : 64'b0;
    assign partial_products[33*64 +: 64] =
        (op_q == 3'd1 && b_q[31]) ? {neg_a, 32'b0} : 64'b0;

    wire [23*64-1:0] mul_l1;
    wire [11*64-1:0] mul_l3;
    wire [6*64-1:0] mul_l5;
    wire [3*64-1:0] mul_l7;
    wire [16*64-1:0] mul_next1;
    wire [8*64-1:0] mul_next2;
    wire [4*64-1:0] mul_next3;
    wire [2*64-1:0] mul_next4;
    logic [16*64-1:0] mul_stage1;
    logic [8*64-1:0] mul_stage2;
    logic [4*64-1:0] mul_stage3;
    logic [2*64-1:0] mul_stage4;
    mul_div_wallace_level #(.N(34)) u_l1 (partial_products, mul_l1);
    mul_div_wallace_level #(.N(23)) u_l2 (mul_l1, mul_next1);
    mul_div_wallace_level #(.N(16)) u_l3 (mul_stage1, mul_l3);
    mul_div_wallace_level #(.N(11)) u_l4 (mul_l3, mul_next2);
    mul_div_wallace_level #(.N(8)) u_l5 (mul_stage2, mul_l5);
    mul_div_wallace_level #(.N(6)) u_l6 (mul_l5, mul_next3);
    mul_div_wallace_level #(.N(4)) u_l7 (mul_stage3, mul_l7);
    mul_div_wallace_level #(.N(3)) u_l8 (mul_l7, mul_next4);
    wire [63:0] product = mul_stage4[63:0] + mul_stage4[127:64];
    wire [31:0] mul_value = (op_q == 3'd0) ? product[31:0] : product[63:32];

    // One restoring-division bit is consumed on each DIV clock edge.
    wire [32:0] trial_remainder = {remainder_q, dividend_shift_q[31]};
    wire subtract = trial_remainder >= {1'b0, divisor_q};
    wire [31:0] next_remainder = subtract ?
        (trial_remainder[31:0] - divisor_q) : trial_remainder[31:0];
    wire [31:0] next_quotient = {quotient_q, subtract};
    wire [31:0] signed_quotient = quotient_negative_q ? -next_quotient : next_quotient;
    wire [31:0] signed_remainder = dividend_negative_q ?
        -next_remainder : next_remainder;
    wire [31:0] div_value = op_q[1] ? signed_remainder : signed_quotient;

    assign exec_ready = (state == IDLE) || (state == RESULT && result_ready);
    assign result_valid = (state == RESULT);
    assign result_payload = result_q;

    always_ff @(posedge clock) begin
        if (reset) begin
            state <= IDLE;
        end else begin
            if (state != IDLE && held_young) begin
                state <= IDLE;
            end else begin
                case (state)
                    MUL: begin
                        case (mul_step)
                            3'd0: mul_stage1 <= mul_next1;
                            3'd1: mul_stage2 <= mul_next2;
                            3'd2: mul_stage3 <= mul_next3;
                            3'd3: mul_stage4 <= mul_next4;
                            default: begin
                                result_q <= {tag_q, pdst_q, mul_value};
                                state <= RESULT;
                            end
                        endcase
                        mul_step <= mul_step + 1'b1;
                    end
                    DIV: begin
                        if (div_step == 6'd31) begin
                            result_q <= {tag_q, pdst_q, div_value};
                            state <= RESULT;
                        end else begin
                            remainder_q <= next_remainder;
                            quotient_q <= next_quotient[30:0];
                            dividend_shift_q <= {dividend_shift_q[30:0], 1'b0};
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
                op_q <= in_op;
                a_q <= in_a;
                b_q <= in_b;
                if (in_op < 3'd4) begin
                    mul_step <= 0;
                    state <= MUL;
                end else if (in_special) begin
                    result_q <= {in_tag, in_pdst, in_special_value};
                    state <= RESULT;
                end else begin
                    divisor_q <= in_abs_b;
                    dividend_shift_q <= in_abs_a;
                    quotient_q <= 0;
                    remainder_q <= 0;
                    dividend_negative_q <= in_signed_div && in_a[31];
                    quotient_negative_q <= in_signed_div && (in_a[31] ^ in_b[31]);
                    div_step <= 0;
                    state <= DIV;
                end
            end
        end
    end
endmodule
