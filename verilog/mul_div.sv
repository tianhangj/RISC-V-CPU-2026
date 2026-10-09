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
    localparam logic [2:0] IDLE = 3'd0, DIV = 3'd1, RESULT = 3'd2, MUL_ADD = 3'd3, MUL_FINISH = 3'd4;
    logic [2:0] state;
    logic [31:0] pp00_q, pp01_q, pp10_q, pp11_q;
    logic [63:0] product_q;
    logic [31:0] correction_a_q, correction_b_q;
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
    // Registered 16x16 partial products, then accumulation, then correction.
    wire [63:0] accumulated_product = {32'b0, pp00_q} +
        {16'b0, pp01_q, 16'b0} + {16'b0, pp10_q, 16'b0} + {pp11_q, 32'b0};
    wire [31:0] corrected_high = product_q[63:32] - correction_a_q - correction_b_q;
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

    always_ff @(posedge clock) begin
        if (reset) begin
            state <= IDLE;
        end else begin
            if (state != IDLE && held_young) begin
                state <= IDLE;
            end else begin
                case (state)
                    MUL_ADD: begin product_q <= accumulated_product; state <= MUL_FINISH; end
                    MUL_FINISH: begin result_q <= {tag_q, pdst_q, mul_value}; state <= RESULT; end
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
                rem_q <= in_op[1];
                if (in_op < 3'd4) begin
                    pp00_q <= in_a[15:0] * in_b[15:0];
                    pp01_q <= in_a[15:0] * in_b[31:16];
                    pp10_q <= in_a[31:16] * in_b[15:0];
                    pp11_q <= in_a[31:16] * in_b[31:16];
                    correction_a_q <= ((in_op == 1 || in_op == 2) && in_a[31]) ? in_b : 0;
                    correction_b_q <= (in_op == 1 && in_b[31]) ? in_a : 0;
                    mul_op_q <= in_op;
                    state <= MUL_ADD;
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
