module smoke #(
    parameter integer WIDTH = 2
);
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    wire [31:0] araddr, awaddr, wdata;
    wire arvalid, arready, rready, awvalid, wvalid, bready;
    wire [3:0] wstrb;
    logic [31:0] rdata;
    logic rvalid = 0, bvalid = 0;
    logic got_aw = 0, got_w = 0;
    logic [31:0] aw_seen, w_seen;
    logic [3:0] strb_seen;
    integer cycles = 0;
    student_top #(.ISSUE_WIDTH(WIDTH), .DISPATCH_WIDTH(WIDTH),
        .WB_WIDTH(WIDTH), .COMMIT_WIDTH(WIDTH)) dut (
        .clock, .reset, .araddr, .arvalid, .arready,
        .rdata, .rresp(2'b0), .rvalid, .rready,
        .awaddr, .awvalid, .awready(1'b1),
        .wdata, .wstrb, .wvalid, .wready(1'b1),
        .bresp(2'b0), .bvalid, .bready
    );
    assign arready = !rvalid;
    function automatic [31:0] instruction(input [31:0] address);
        case (address)
            0: instruction = 32'h800002b7; // lui x5,0x80000
            4: instruction = 32'h02a00513; // addi x10,x0,42
            8: instruction = 32'h00a2a023; // sw x10,0(x5)
            default: instruction = 32'h0000006f;
        endcase
    endfunction
    initial begin
        repeat (5) @(posedge clock);
        @(negedge clock) reset = 0;
        repeat (250) @(posedge clock);
        $fatal(1, "CPU failed to issue the exit store");
    end
    always @(posedge clock) begin
        if (reset) begin
            rvalid <= 0;
            bvalid <= 0;
            got_aw <= 0;
            got_w <= 0;
        end else begin
            cycles <= cycles + 1;
            if (rvalid && rready) rvalid <= 0;
            if (arvalid && !rvalid) begin
                rvalid <= 1;
                rdata <= instruction(araddr);
            end
            if (awvalid) begin
                got_aw <= 1;
                aw_seen <= awaddr;
            end
            if (wvalid) begin
                got_w <= 1;
                w_seen <= wdata;
                strb_seen <= wstrb;
            end
            if (got_aw && got_w && !bvalid) bvalid <= 1;
            if (bvalid && bready) begin
                if (aw_seen !== 32'h80000000 || w_seen !== 32'd42 || strb_seen !== 4'hf)
                    $fatal(1, "bad exit store addr=%h data=%h strb=%h", aw_seen, w_seen, strb_seen);
                $display("PASS exit store after %0d cycles", cycles);
                $finish;
            end
        end
    end
endmodule
