module axi_bridge #(
    parameter integer LQ_DEPTH = 8,
    parameter integer FETCH_QUEUE_DEPTH = 16,
    parameter integer AXI_RD_OUTSTANDING = 16,
    parameter integer GEN_WIDTH = 16,
    parameter integer LIDW = (LQ_DEPTH > 1) ? $clog2(LQ_DEPTH) : 1,
    parameter integer FIDW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1,
    parameter integer IF_ID_WIDTH = FIDW,
    parameter integer IF_REQ_BITS = GEN_WIDTH + IF_ID_WIDTH + 32,
    parameter integer IF_RSP_BITS = GEN_WIDTH + IF_ID_WIDTH + 32,
    parameter integer LD_REQ_BITS = GEN_WIDTH + LIDW + 32,
    parameter integer LD_RSP_BITS = GEN_WIDTH + LIDW + 32,
    parameter integer WRITE_REQ_BITS = 68
) (
    input logic clock, reset,
    input logic if_req_valid,
    output logic if_req_ready,
    input logic [IF_REQ_BITS-1:0] if_req_payload,
    output logic if_rsp_valid,
    output logic [IF_RSP_BITS-1:0] if_rsp_payload,
    input logic ld_req_valid,
    output logic ld_req_ready,
    input logic [LD_REQ_BITS-1:0] ld_req_payload,
    output logic ld_rsp_valid,
    output logic [LD_RSP_BITS-1:0] ld_rsp_payload,
    input logic st_req_valid,
    output logic st_req_ready,
    input logic [WRITE_REQ_BITS-1:0] st_req_payload,
    output logic st_rsp_valid,
    output logic [31:0] araddr,
    output logic arvalid,
    input logic arready,
    input logic [31:0] rdata,
    input logic [1:0] rresp,
    input logic rvalid,
    output logic rready,
    output logic [31:0] awaddr,
    output logic awvalid,
    input logic awready,
    output logic [31:0] wdata,
    output logic [3:0] wstrb,
    output logic wvalid,
    input logic wready,
    input logic [1:0] bresp,
    input logic bvalid,
    output logic bready
);
    localparam integer QW = (AXI_RD_OUTSTANDING > 1) ? $clog2(AXI_RD_OUTSTANDING) : 1;
    localparam integer CW = $clog2(AXI_RD_OUTSTANDING + 1);
    localparam integer MIDW = (LIDW > IF_ID_WIDTH) ? LIDW : IF_ID_WIDTH;
    logic [31:0] address [0:AXI_RD_OUTSTANDING-1];
    logic [GEN_WIDTH-1:0] generation [0:AXI_RD_OUTSTANDING-1];
    logic [MIDW-1:0] identifier [0:AXI_RD_OUTSTANDING-1];
    logic is_load [0:AXI_RD_OUTSTANDING-1];
    logic [QW-1:0] enqueue_q, ar_q, response_q;
    logic [CW-1:0] unsent_q, sent_q;
    logic prefer_load;
    wire space = (unsent_q + sent_q) < AXI_RD_OUTSTANDING;
    wire read_accept = (if_req_valid && if_req_ready) || (ld_req_valid && ld_req_ready);
    wire accept_load = ld_req_valid && ld_req_ready;
    wire ar_fire = arvalid && arready;
    wire r_fire = rvalid && rready;
    wire st_accept = st_req_valid && st_req_ready;
    logic write_busy, aw_pending, w_pending;
    logic [WRITE_REQ_BITS-1:0] write_q;

    always_comb begin
        if_req_ready = 0;
        ld_req_ready = 0;
        if (space) begin
            if (if_req_valid && ld_req_valid) begin
                if_req_ready = !prefer_load;
                ld_req_ready = prefer_load;
            end else begin
                if_req_ready = if_req_valid;
                ld_req_ready = ld_req_valid;
            end
        end
    end
    assign arvalid = unsent_q != 0;
    assign araddr = address[ar_q];
    assign rready = sent_q != 0;
    assign if_rsp_valid = r_fire && !is_load[response_q];
    assign ld_rsp_valid = r_fire && is_load[response_q];
    assign if_rsp_payload = {generation[response_q], identifier[response_q][IF_ID_WIDTH-1:0], rdata};
    assign ld_rsp_payload = {generation[response_q], identifier[response_q][LIDW-1:0], rdata};
    assign st_req_ready = !write_busy;
    assign awaddr = write_q[WRITE_REQ_BITS-1 -: 32];
    assign wdata = write_q[35:4];
    assign wstrb = write_q[3:0];
    assign awvalid = write_busy && aw_pending;
    assign wvalid = write_busy && w_pending;
    assign bready = write_busy && !aw_pending && !w_pending;
    assign st_rsp_valid = bvalid && bready;

    always_ff @(posedge clock) begin
        if (reset) begin
            enqueue_q <= 0;
            ar_q <= 0;
            response_q <= 0;
            unsent_q <= 0;
            sent_q <= 0;
            prefer_load <= 0;
            write_busy <= 0;
            aw_pending <= 0;
            w_pending <= 0;
        end else begin
            if (read_accept) begin
                is_load[enqueue_q] <= accept_load;
                if (accept_load) begin
                    address[enqueue_q] <= ld_req_payload[31:0];
                    identifier[enqueue_q] <= ld_req_payload[32 +: LIDW];
                    generation[enqueue_q] <= ld_req_payload[32+LIDW +: GEN_WIDTH];
                end else begin
                    address[enqueue_q] <= if_req_payload[31:0];
                    identifier[enqueue_q] <= MIDW'(if_req_payload[32 +: IF_ID_WIDTH]);
                    generation[enqueue_q] <= if_req_payload[32+IF_ID_WIDTH +: GEN_WIDTH];
                end
                enqueue_q <= (enqueue_q == AXI_RD_OUTSTANDING-1) ? 0 : enqueue_q + 1'b1;
                prefer_load <= !accept_load;
            end
            if (ar_fire) ar_q <= (ar_q == AXI_RD_OUTSTANDING-1) ? 0 : ar_q + 1'b1;
            if (r_fire) response_q <= (response_q == AXI_RD_OUTSTANDING-1) ? 0 : response_q + 1'b1;
            unsent_q <= unsent_q + read_accept - ar_fire;
            sent_q <= sent_q + ar_fire - r_fire;
            if (st_accept) begin
                write_q <= st_req_payload;
                write_busy <= 1;
                aw_pending <= 1;
                w_pending <= 1;
            end
            if (awvalid && awready) aw_pending <= 0;
            if (wvalid && wready) w_pending <= 0;
            if (st_rsp_valid) write_busy <= 0;
        end
    end
endmodule
