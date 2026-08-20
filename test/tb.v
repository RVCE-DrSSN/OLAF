`default_nettype none
`timescale 1ns / 1ps

/*
 * OLAF-8 Tiny Tapeout Testbench
 *
 * This testbench instantiates the Tiny Tapeout top-level module:
 *     tt_um_olaf8
 *
 * Inputs:
 *   ui_in[7:4] = x1
 *   ui_in[3:0] = x2
 *   uio_in[0]  = start
 *
 * Outputs:
 *   uo_out[3:0] = fuzzy output
 *   uo_out[4]   = done
 *   uo_out[5]   = rule admitted
 *   uo_out[6]   = busy
 */

module tb ();

  // Dump signals for waveform inspection.
  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end

  // Tiny Tapeout interface signals.
  reg        clk;
  reg        rst_n;
  reg        ena;
  reg [7:0]  ui_in;
  reg [7:0]  uio_in;

  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

  // Instantiate OLAF-8.
  tt_um_olaf8 user_project (

`ifdef GL_TEST
      .VPWR(VPWR),
      .VGND(VGND),
`endif

      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

endmodule

`default_nettype wire
