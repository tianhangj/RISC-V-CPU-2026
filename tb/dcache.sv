module dcache_case #(parameter integer LINE = 32, SETS = 4)(output reg done);
    localparam integer IW = $clog2(LINE/4);
    localparam integer MB = 16+IW+32;
    reg clock = 0;
    always #5 clock = ~clock;
    reg reset = 1, ld_req_valid = 0, st_req_valid = 0;
    reg [49:0] ld_req_payload = 0;
    reg [67:0] st_req_payload = 0;
    wire ld_req_ready, ld_rsp_valid, st_req_ready, st_rsp_valid;
    wire [49:0] ld_rsp_payload;
    wire ml_valid, ml_ready, ml_rsp_valid, ms_valid, ms_ready, ms_rsp_valid;
    wire [MB-1:0] ml_payload, ml_rsp_payload;
    wire [67:0] ms_payload;
    wire [31:0] araddr, awaddr, wdata;
    wire [3:0] wstrb;
    wire arvalid, arready, rready, awvalid, awready, wvalid, wready, bready;
    reg [31:0] memory [0:2047];
    reg [31:0] ra [0:31], wa [0:31], wd [0:31];
    reg [3:0] wm [0:31];
    integer rdue [0:31], bdue [0:31];
    integer rh = 0, rt = 0, rc = 0, ah = 0, at = 0, ac = 0;
    integer wh = 0, wt = 0, wc = 0, bh = 0, bt = 0, bc = 0;
    integer cycles = 0, reads = 0, writes = 0, exits = 0, responses = 0;
    integer reads_before;
    reg ar_stalled = 0, aw_stalled = 0, w_stalled = 0;
    reg [31:0] saved_ar, saved_aw, saved_w;
    reg [3:0] saved_mask;
    wire rvalid = rc != 0 && cycles >= rdue[rh] && cycles%7 != 2;
    wire [31:0] rdata = memory[ra[rh] >> 2];
    wire bvalid = bc != 0 && cycles >= bdue[bh] && cycles%5 != 2;
    wire pair_write = ac != 0 && wc != 0 && bc < 16;
    assign arready = rc < 16 && cycles%5 != 1;
    assign awready = ac < 16 && cycles%4 != 1;
    assign wready = wc < 16 && cycles%6 != 3;
    dcache #(.SIZE_BYTES(SETS*LINE), .LINE_BYTES(LINE)) dut (
        .clock, .reset, .ld_req_valid, .ld_req_ready, .ld_req_payload,
        .ld_rsp_valid, .ld_rsp_payload, .st_req_valid, .st_req_ready,
        .st_req_payload, .st_rsp_valid,
        .mem_ld_req_valid(ml_valid), .mem_ld_req_ready(ml_ready), .mem_ld_req_payload(ml_payload),
        .mem_ld_rsp_valid(ml_rsp_valid), .mem_ld_rsp_payload(ml_rsp_payload),
        .mem_st_req_valid(ms_valid), .mem_st_req_ready(ms_ready), .mem_st_req_payload(ms_payload),
        .mem_st_rsp_valid(ms_rsp_valid));
    axi_bridge #(.LQ_DEPTH(LINE/4), .IF_ID_WIDTH(1),
        .AXI_RD_OUTSTANDING(5), .AXI_WR_OUTSTANDING(3)) bridge (
        .clock, .reset, .if_req_valid(1'b0), .if_req_ready(), .if_req_payload(49'b0),
        .if_rsp_valid(), .if_rsp_payload(), .ld_req_valid(ml_valid), .ld_req_ready(ml_ready),
        .ld_req_payload(ml_payload), .ld_rsp_valid(ml_rsp_valid), .ld_rsp_payload(ml_rsp_payload),
        .st_req_valid(ms_valid), .st_req_ready(ms_ready), .st_req_payload(ms_payload),
        .st_rsp_valid(ms_rsp_valid), .araddr, .arvalid, .arready, .rdata, .rresp(2'b0),
        .rvalid, .rready, .awaddr, .awvalid, .awready, .wdata, .wstrb, .wvalid, .wready,
        .bresp(2'b0), .bvalid, .bready);
    always @(posedge clock) if (!reset) begin
        cycles <= cycles+1;
        if (cycles > 6000) $fatal(1, "dcache timeout LINE=%0d", LINE);
        if (ar_stalled && (!arvalid || araddr !== saved_ar)) $fatal(1, "AR changed while stalled");
        if (aw_stalled && (!awvalid || awaddr !== saved_aw)) $fatal(1, "AW changed while stalled");
        if (w_stalled && (!wvalid || wdata !== saved_w || wstrb !== saved_mask))
            $fatal(1, "W changed while stalled");
        ar_stalled <= arvalid && !arready; saved_ar <= araddr;
        aw_stalled <= awvalid && !awready; saved_aw <= awaddr;
        w_stalled <= wvalid && !wready; saved_w <= wdata; saved_mask <= wstrb;
        if (arvalid && arready) begin
            if (araddr[1:0] != 0 || araddr >= 8192) $fatal(1, "bad refill address");
            ra[rt] <= araddr; rdue[rt] <= cycles+10; rt <= (rt+1)%32; reads <= reads+1;
        end
        if (rvalid && rready) rh <= (rh+1)%32;
        rc <= rc+int'(arvalid && arready)-int'(rvalid && rready);
        if (awvalid && awready) begin wa[at] <= awaddr; at <= (at+1)%32; end
        if (wvalid && wready) begin wd[wt] <= wdata; wm[wt] <= wstrb; wt <= (wt+1)%32; end
        ac <= ac+int'(awvalid && awready)-int'(pair_write);
        wc <= wc+int'(wvalid && wready)-int'(pair_write);
        if (pair_write) begin
            if (wa[ah] == 32'h80000000) begin
                if (wd[wh] !== 42 || wm[wh] !== 15) $fatal(1, "bad MMIO write");
                if (memory[0] !== 32'hdeadbbef || memory[LINE/4] !== 32'h12345678)
                    $fatal(1, "MMIO preceded dirty data writeback");
                if (SETS > 16 && memory[16*LINE/4] !== 32'h87654321)
                    $fatal(1, "MMIO lost a dirty line from another tag group");
                exits <= exits+1;
            end else begin
                if (wa[ah] >= 8192 || wa[ah][1:0] != 0) $fatal(1, "bad writeback address");
                for (integer b = 0; b < 4; b = b+1)
                    if (wm[wh][b]) memory[wa[ah] >> 2][8*b +: 8] <= wd[wh][8*b +: 8];
                writes <= writes+1;
            end
            ah <= (ah+1)%32; wh <= (wh+1)%32;
            bdue[bt] <= cycles+10; bt <= (bt+1)%32;
        end
        if (bvalid && bready) bh <= (bh+1)%32;
        bc <= bc+int'(pair_write)-int'(bvalid && bready);
        if (ld_rsp_valid) responses <= responses+1;
    end
    task automatic load(input [31:0] address, expected, input [15:0] generation, input [1:0] id);
        @(negedge clock);
        ld_req_valid = 1;
        ld_req_payload = {generation, id, address};
        do @(posedge clock); while (!ld_req_ready);
        @(negedge clock) begin ld_req_valid = 0; ld_req_payload = '1; end
        while (!ld_rsp_valid) @(negedge clock);
        if (ld_rsp_payload !== {generation, id, expected})
            $fatal(1, "load LINE=%0d address=%h got=%h expected=%h", LINE, address, ld_rsp_payload, expected);
        @(posedge clock);
    endtask
    task automatic store(input [31:0] address, data, input [3:0] mask);
        @(negedge clock);
        st_req_valid = 1;
        st_req_payload = {address, data, mask};
        do @(posedge clock); while (!st_req_ready);
        @(negedge clock) st_req_valid = 0;
        while (!st_rsp_valid) @(negedge clock);
        @(posedge clock);
    endtask
    initial begin
        done = 0;
        for (integer i = 0; i < 2048; i = i+1) memory[i] = 32'ha5000000+32'(4*i);
        repeat (3) @(posedge clock);
        @(negedge clock) reset = 0;
        load(0, 32'ha5000000, 16'hffff, 0);
        if (dut.state != 4) $fatal(1, "critical load word waited for the entire line");
        while (dut.state != 0) @(negedge clock);
        if (reads != LINE/4) $fatal(1, "miss did not fill exactly one line");
        reads_before = reads;
        load(LINE-4, 32'ha5000000+LINE-4, 16'h1111, 3);
        if (reads != reads_before) $fatal(1, "filled word missed");
        // Back-to-back hit requests must retain one response per cycle, with
        // the matching generation/id even as input identity changes.
        for (integer i = 0; i < 4; i = i+1) begin
            @(negedge clock);
            ld_req_valid = 1;
            ld_req_payload = {16'(16'h1000+i), 2'(i), 32'd0};
            if (!ld_req_ready) $fatal(1, "cache hit throughput bubble");
            @(posedge clock); #1;
            if (!ld_rsp_valid || ld_rsp_payload !== {16'(16'h1000+i), 2'(i), 32'ha5000000})
                $fatal(1, "back-to-back hit identity corrupted");
        end
        @(negedge clock) ld_req_valid = 0;
        @(posedge clock); #1;
        if (ld_rsp_valid || reads != reads_before) $fatal(1, "duplicate hit or unnecessary refill");
        store(0, 32'hdeadbeef, 15);
        store(0, 32'h0000bb00, 2);
        load(0, 32'hdeadbbef, 16'h2222, 1);
        if (memory[0] === 32'hdeadbbef) $fatal(1, "write-back hit reached AXI early");
        load(SETS*LINE, 32'ha5000000+SETS*LINE, 16'h3333, 2);
        if (memory[0] !== 32'hdeadbbef || writes != LINE/4)
            $fatal(1, "dirty victim lost data");
        load(0, 32'hdeadbbef, 16'h4444, 2);
        store(LINE, 32'h12345678, 15);
        store(0, 32'hdeadbbef, 15);
        if (SETS > 16) begin
            load(16*LINE, 32'ha5000000+16*LINE, 16'h7777, 3);
            store(16*LINE, 32'h87654321, 15);
            load(16*LINE, 32'h87654321, 16'h8888, 0);
        end
        store(32'h80000000, 42, 15);
        if (exits != 1 || bc != 0) $fatal(1, "MMIO completion before B response");
        // Reset invalidates metadata without relying on initialized SRAM.
        @(negedge clock) reset = 1;
        @(posedge clock);
        @(negedge clock) reset = 0;
        reads_before = reads;
        load(0, 32'hdeadbbef, 16'h5555, 0);
        while (dut.state != 0) @(negedge clock);
        if (reads != reads_before+LINE/4) $fatal(1, "reset retained valid cache entry");
        $display("PASS dcache LINE=%0d SETS=%0d", LINE, SETS);
        done = 1;
    end
endmodule
module dcache_test;
    wire [4:0] done;
    dcache_case #(.LINE(16)) a(done[0]);
    dcache_case #(.LINE(32)) b(done[1]);
    dcache_case #(.LINE(64)) c(done[2]);
    dcache_case #(.LINE(32), .SETS(1)) d(done[3]);
    dcache_case #(.LINE(32), .SETS(32)) e(done[4]);
    initial begin wait (&done); $finish; end
endmodule
