/*
 * OLAF-8: Drastic-area experimental candidate
 * Tiny Tapeout SKY130 / Verilog
 *
 * AREA-FIRST ARCHITECTURAL CHANGE:
 * The original weighted singleton-centroid datapath
 * (8x product accumulation + restoring divider) is removed.
 *
 * New defuzzification:
 *   y = consequent of the rule with maximum MIN firing strength
 *       (winner-take-all / max-fire singleton output)
 *
 * Preserved:
 *   - 8 bounded rule slots
 *   - 2-input fuzzy membership
 *   - MIN firing strength
 *   - firing-strength-gated online admission
 *   - least-utility rule replacement
 *   - shared streaming datapath
 *   - observable admission output
 *   - Tiny Tapeout interface
 *
 * IMPORTANT:
 * This is intentionally a drastic architectural experiment.
 * It is NOT numerically equivalent to the original weighted-average
 * output. Existing expected y-values may therefore change.
 * The <=566-cell target must be confirmed by synthesis/GDS.
 */

`default_nettype none

module tt_um_olaf8 (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    wire [3:0] y;
    wire       done;
    wire       admitted;
    wire       busy;

    olaf8_core core (
        .x1(ui_in[7:4]),
        .x2(ui_in[3:0]),
        .start(uio_in[0] & ena),
        .clk(clk),
        .rst_n(rst_n),
        .y(y),
        .done(done),
        .admitted(admitted),
        .busy(busy)
    );

    assign uo_out  = {1'b0, busy, admitted, done, y};
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

endmodule


module olaf8_core (
    input  wire [3:0] x1,
    input  wire [3:0] x2,
    input  wire       start,
    input  wire       clk,
    input  wire       rst_n,

    output reg [3:0] y,
    output reg       done,
    output reg       admitted,
    output reg       busy
);

    /*
     * Packed rule:
     * [10:9] antecedent 1
     * [ 8:7] antecedent 2
     * [ 6:3] consequent
     * [ 2:0] utility
     */
    reg [10:0] rule [0:7];

    reg [3:0] x1_r;
    reg [3:0] x2_r;

    reg [2:0] rule_idx;

    /* Winner so far. */
    reg [3:0] max_fire;
    reg [2:0] max_idx;
    reg [3:0] max_y;

    /* Least-utility slot so far. */
    reg [2:0] min_util;
    reg [2:0] min_idx;

    /*
     * One shared membership evaluator.
     * phase=0: evaluate x1 / antecedent 1
     * phase=1: evaluate x2 / antecedent 2
     *
     * Two cycles per rule => 16 cycles total.
     */
    reg       mem_phase;
    reg [3:0] m1_hold;

    reg state;
    localparam S_IDLE = 1'b0;
    localparam S_SCAN = 1'b1;


    // ============================================================
    // Exact finite membership mapping
    // ============================================================

    function [3:0] membership;
        input [3:0] x;
        input [1:0] label;

        begin
            case (label)

                2'd0: begin
                    case (x)
                        4'd0: membership = 4'd15;
                        4'd1: membership = 4'd13;
                        4'd2: membership = 4'd11;
                        4'd3: membership = 4'd9;
                        4'd4: membership = 4'd7;
                        4'd5: membership = 4'd5;
                        4'd6: membership = 4'd3;
                        4'd7: membership = 4'd1;
                        default: membership = 4'd0;
                    endcase
                end

                2'd1: begin
                    case (x)
                        4'd0:  membership = 4'd0;
                        4'd1:  membership = 4'd2;
                        4'd2:  membership = 4'd4;
                        4'd3:  membership = 4'd6;
                        4'd4:  membership = 4'd8;
                        4'd5:  membership = 4'd10;
                        4'd6:  membership = 4'd12;
                        4'd7:  membership = 4'd14;
                        4'd8:  membership = 4'd14;
                        4'd9:  membership = 4'd12;
                        4'd10: membership = 4'd10;
                        4'd11: membership = 4'd8;
                        4'd12: membership = 4'd6;
                        4'd13: membership = 4'd4;
                        4'd14: membership = 4'd2;
                        default: membership = 4'd0;
                    endcase
                end

                default: begin
                    case (x)
                        4'd0,
                        4'd1,
                        4'd2,
                        4'd3,
                        4'd4,
                        4'd5,
                        4'd6,
                        4'd7:  membership = 4'd0;
                        4'd8:  membership = 4'd2;
                        4'd9:  membership = 4'd4;
                        4'd10: membership = 4'd6;
                        4'd11: membership = 4'd8;
                        4'd12: membership = 4'd10;
                        4'd13: membership = 4'd12;
                        4'd14: membership = 4'd14;
                        default: membership = 4'd15;
                    endcase
                end

            endcase
        end
    endfunction


    // ============================================================
    // Peak label for admission
    // ============================================================

    function [1:0] peak_label;
        input [3:0] x;
        begin
            if (x <= 4'd3)
                peak_label = 2'd0;
            else if (x <= 4'd11)
                peak_label = 2'd1;
            else
                peak_label = 2'd2;
        end
    endfunction


    // ============================================================
    // Current rule
    // ============================================================

    wire [10:0] cur_rule = rule[rule_idx];

    wire [1:0] cur_a1 = cur_rule[10:9];
    wire [1:0] cur_a2 = cur_rule[8:7];
    wire [3:0] cur_y  = cur_rule[6:3];
    wire [2:0] cur_u  = cur_rule[2:0];


    // Shared membership result.
    wire [3:0] mem_now =
        mem_phase
        ? membership(x2_r, cur_a2)
        : membership(x1_r, cur_a1);


    // Final firing strength for the current rule.
    wire [3:0] cur_fire =
        (m1_hold < mem_now)
        ? m1_hold
        : mem_now;


    // Final winner including the current rule.
    wire final_is_current =
        (cur_fire > max_fire);


    wire [3:0] final_fire =
        final_is_current ? cur_fire : max_fire;

    wire [3:0] final_y =
        final_is_current ? cur_y : max_y;

    wire [2:0] final_winner_idx =
        final_is_current ? rule_idx : max_idx;


    // Final least-utility slot including current rule.
    wire final_is_current_min =
        (cur_u < min_util);

    wire [2:0] final_replace_idx =
        final_is_current_min ? rule_idx : min_idx;


    // ============================================================
    // Sequential engine
    // ============================================================

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state    <= S_IDLE;

            y        <= 4'd8;
            done     <= 1'b0;
            admitted <= 1'b0;
            busy     <= 1'b0;

            x1_r <= 4'd0;
            x2_r <= 4'd0;

            rule_idx <= 3'd0;

            max_fire <= 4'd0;
            max_idx  <= 3'd0;
            max_y    <= 4'd8;

            min_util <= 3'd7;
            min_idx  <= 3'd0;

            mem_phase <= 1'b0;
            m1_hold   <= 4'd0;


            /* Same deterministic initial 8-rule base. */
            rule[0] <= 11'b00_00_0010_001;
            rule[1] <= 11'b00_01_0101_001;
            rule[2] <= 11'b00_10_0111_001;
            rule[3] <= 11'b01_00_0101_001;
            rule[4] <= 11'b01_01_1000_001;
            rule[5] <= 11'b01_10_1010_001;
            rule[6] <= 11'b10_00_0111_001;
            rule[7] <= 11'b10_10_1101_001;

        end

        else begin

            done     <= 1'b0;
            admitted <= 1'b0;

            case (state)

                // ==================================================
                // IDLE
                // ==================================================

                S_IDLE: begin

                    busy <= 1'b0;

                    if (start) begin

                        x1_r <= x1;
                        x2_r <= x2;

                        rule_idx <= 3'd0;

                        max_fire <= 4'd0;
                        max_idx  <= 3'd0;
                        max_y    <= 4'd8;

                        min_util <= 3'd7;
                        min_idx  <= 3'd0;

                        mem_phase <= 1'b0;
                        m1_hold   <= 4'd0;

                        busy  <= 1'b1;
                        state <= S_SCAN;

                    end

                end


                // ==================================================
                // SHARED 2-CYCLE RULE EVALUATION
                // ==================================================

                S_SCAN: begin

                    busy <= 1'b1;

                    if (!mem_phase) begin

                        /*
                         * First half:
                         * calculate membership of antecedent 1.
                         */
                        m1_hold   <= mem_now;
                        mem_phase <= 1'b1;

                    end

                    else begin

                        /*
                         * Second half:
                         * calculate antecedent 2, then MIN.
                         */

                        /* Update running winner. */
                        if (cur_fire > max_fire) begin
                            max_fire <= cur_fire;
                            max_idx  <= rule_idx;
                            max_y    <= cur_y;
                        end

                        /* Update running least-utility slot. */
                        if (cur_u < min_util) begin
                            min_util <= cur_u;
                            min_idx  <= rule_idx;
                        end

                        mem_phase <= 1'b0;

                        if (rule_idx == 3'd7) begin

                            /*
                             * Finalize using the current rule as well.
                             * This avoids the usual nonblocking-assignment
                             * last-cycle omission.
                             */
                            y <= final_y;

                            /*
                             * Core admission mechanism is unchanged:
                             * weak maximum firing => admit/replace.
                             */
                            if (final_fire < 4'd6) begin

                                rule[final_replace_idx][10:9]
                                    <= peak_label(x1_r);

                                rule[final_replace_idx][8:7]
                                    <= peak_label(x2_r);

                                /*
                                 * In winner-take-all mode, the new rule's
                                 * consequent is the inferred winner output.
                                 */
                                rule[final_replace_idx][6:3]
                                    <= final_y;

                                rule[final_replace_idx][2:0]
                                    <= 3'd4;

                                admitted <= 1'b1;

                            end

                            else begin

                                if (rule[final_winner_idx][2:0] != 3'd7)
                                    rule[final_winner_idx][2:0]
                                        <= rule[final_winner_idx][2:0] + 3'd1;

                            end

                            done  <= 1'b1;
                            busy  <= 1'b0;
                            state <= S_IDLE;

                        end

                        else begin

                            rule_idx <= rule_idx + 3'd1;

                        end

                    end

                end


                default: begin
                    state <= S_IDLE;
                end

            endcase

        end

    end

endmodule

`default_nettype wire
