# Sources for the scene and the CPU renderer

- The rounded rectangle distance function is the common signed distance form for a box with four corner radii. The code is written fresh from the formula in the task text.
- The gradient line length rule follows the CSS Images module: the length is the sum of the absolute width times the sine and the absolute height times the cosine of the angle.
- The PNG file format follows the PNG specification (chunk layout, CRC-32, and the five filter types). The compressed data uses `std.compress.flate`.
