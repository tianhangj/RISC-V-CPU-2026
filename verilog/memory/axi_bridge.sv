module axi_bridge #(
    parameter integer LD_ID_WIDTH = 6,
    parameter integer AXI_RD_OUTSTANDING = 16,
    parameter integer AXI_WR_OUTSTANDING = 16,
    parameter integer GEN_WIDTH = 16,
    parameter integer IF_ID_WIDTH = 3
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
    localparam integer IF_REQ_BITS = GEN_WIDTH + IF_ID_WIDTH + 32;
    localparam integer IF_RSP_BITS = GEN_WIDTH + IF_ID_WIDTH + 32;
    localparam integer LD_REQ_BITS = GEN_WIDTH + LD_ID_WIDTH + 32;
    localparam integer LD_RSP_BITS = GEN_WIDTH + LD_ID_WIDTH + 32;
    localparam integer WRITE_REQ_BITS = 68;
    localparam integer QW = (AXI_RD_OUTSTANDING > 1) ? $clog2(AXI_RD_OUTSTANDING) : 1;
    localparam integer CW = $clog2(AXI_RD_OUTSTANDING + 1);
    localparam integer MIDW = (LD_ID_WIDTH > IF_ID_WIDTH) ? LD_ID_WIDTH : IF_ID_WIDTH;
    logic [QW-1:0] enqueue_q, ar_q, response_q;
    logic [CW-1:0] unsent_q, sent_q;
    logic prefer_load;
    wire space = (unsent_q + sent_q) < AXI_RD_OUTSTANDING;
    wire read_accept = (if_req_valid && if_req_ready) || (ld_req_valid && ld_req_ready);
    wire accept_load = ld_req_valid && ld_req_ready;
    wire ar_fire = arvalid && arready;
    wire r_fire = rvalid && rready;
    wire st_accept = st_req_valid && st_req_ready;
    localparam integer WQW = (AXI_WR_OUTSTANDING > 1) ? $clog2(AXI_WR_OUTSTANDING) : 1;
    localparam integer WCW = $clog2(AXI_WR_OUTSTANDING + 1);
    logic [WQW-1:0] write_tail, aw_head, w_head;
    logic [WCW-1:0] write_count, aw_count, w_count;
    wire aw_fire = awvalid && awready;
    wire w_fire = wvalid && wready;
    localparam integer META_BITS=GEN_WIDTH+MIDW+1;
    wire [31:0] accepted_address=accept_load?ld_req_payload[31:0]:if_req_payload[31:0];
    wire [META_BITS-1:0] accepted_meta=accept_load?
        {ld_req_payload[32+LD_ID_WIDTH +: GEN_WIDTH],MIDW'(ld_req_payload[32 +: LD_ID_WIDTH]),1'b1}:
        {if_req_payload[32+IF_ID_WIDTH +: GEN_WIDTH],MIDW'(if_req_payload[32 +: IF_ID_WIDTH]),1'b0};
    wire [META_BITS-1:0] response_meta;
    wire [2*WRITE_REQ_BITS-1:0] write_ports;
    payload_ram #(.DEPTH(AXI_RD_OUTSTANDING), .WIDTH(32)) read_addresses (
        .clock(clock), .reset(reset), .write_valid(read_accept), .write_addr(enqueue_q),
        .write_data(accepted_address), .read_addr(ar_q), .read_data(araddr));
    payload_ram #(.DEPTH(AXI_RD_OUTSTANDING), .WIDTH(META_BITS)) read_identities (
        .clock(clock), .reset(reset), .write_valid(read_accept), .write_addr(enqueue_q),
        .write_data(accepted_meta), .read_addr(response_q), .read_data(response_meta));
    payload_ram #(.DEPTH(AXI_WR_OUTSTANDING), .WIDTH(WRITE_REQ_BITS), .READ_PORTS(2)) write_requests (
        .clock(clock), .reset(reset), .write_valid(st_accept), .write_addr(write_tail),
        .write_data(st_req_payload), .read_addr({w_head,aw_head}), .read_data(write_ports));

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
    assign rready = sent_q != 0;
    assign if_rsp_valid = r_fire && !response_meta[0];
    assign ld_rsp_valid = r_fire && response_meta[0];
    assign if_rsp_payload = {response_meta[META_BITS-1 -: GEN_WIDTH], response_meta[1 +: IF_ID_WIDTH], rdata};
    assign ld_rsp_payload = {response_meta[META_BITS-1 -: GEN_WIDTH], response_meta[1 +: LD_ID_WIDTH], rdata};
    assign st_req_ready = write_count < AXI_WR_OUTSTANDING;
    assign awaddr = write_ports[WRITE_REQ_BITS-1 -: 32];
    assign wdata = write_ports[WRITE_REQ_BITS+4 +: 32];
    assign wstrb = write_ports[WRITE_REQ_BITS +: 4];
    assign awvalid = aw_count != 0;
    assign wvalid = w_count != 0;
    // A response is eligible only after both halves of its request have left.
    assign bready = write_count > aw_count && write_count > w_count;
    assign st_rsp_valid = bvalid && bready;

    always_ff @(posedge clock) begin
        if (reset) begin
            enqueue_q <= 0;
            ar_q <= 0;
            response_q <= 0;
            unsent_q <= 0;
            sent_q <= 0;
            prefer_load <= 0;
            write_tail <= 0;
            aw_head <= 0;
            w_head <= 0;
            write_count <= 0;
            aw_count <= 0;
            w_count <= 0;
        end else begin
            if (read_accept) begin
                enqueue_q <= (enqueue_q == AXI_RD_OUTSTANDING-1) ? 0 : enqueue_q + 1'b1;
                prefer_load <= !accept_load;
            end
            if (ar_fire) ar_q <= (ar_q == AXI_RD_OUTSTANDING-1) ? 0 : ar_q + 1'b1;
            if (r_fire) response_q <= (response_q == AXI_RD_OUTSTANDING-1) ? 0 : response_q + 1'b1;
            unsent_q <= unsent_q + read_accept - ar_fire;
            sent_q <= sent_q + ar_fire - r_fire;
            if (st_accept) begin
                write_tail <= (write_tail == AXI_WR_OUTSTANDING-1) ? 0 : write_tail + 1'b1;
            end
            if (aw_fire) aw_head <= (aw_head == AXI_WR_OUTSTANDING-1) ? 0 : aw_head + 1'b1;
            if (w_fire) w_head <= (w_head == AXI_WR_OUTSTANDING-1) ? 0 : w_head + 1'b1;
            write_count <= write_count + st_accept - st_rsp_valid;
            aw_count <= aw_count + st_accept - aw_fire;
            w_count <= w_count + st_accept - w_fire;
        end
    end
endmodule
