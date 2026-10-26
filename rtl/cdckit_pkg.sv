// -----------------------------------------------------------------------------
// cdckit_pkg
// Common functions of CDCKIT
// -----------------------------------------------------------------------------
package cdckit_pkg;

  // Maximum pointer width supported by functions. Callers zero-extend and truncate to the real pointer width.
  localparam int unsigned PTR_MAX_W = 32;

  // Binary to Gray
  function automatic logic [PTR_MAX_W-1:0] bin2gray(input logic [PTR_MAX_W-1:0] bin);
    return bin ^ (bin >> 1);
  endfunction

  // Gray to binary: using the process inverse to the bin2gray function
  function automatic logic [PTR_MAX_W-1:0] gray2bin(input logic [PTR_MAX_W-1:0] gray);
    logic [PTR_MAX_W-1:0] bin;

    bin[PTR_MAX_W-1] = gray[PTR_MAX_W-1];

    for (int i = PTR_MAX_W - 2; i >= 0; i--) begin
      bin[i] = bin[i+1] ^ gray[i];
    end
    return bin;
  endfunction

endpackage : cdckit_pkg
