/* SPDX-License-Identifier: MIT
 * Memory-only front end for Fabrice Bellard's genuine libbpg encoder.
 * The generated core retains all upstream copyright and license notices.
 */
#include "mesh_bpg_encoder_core.c"

int mesh_bpg_encode_rgba(const uint8_t *rgba, int width, int height, int quality,
                         BPGEncoderWriteFunc *write_func, void *opaque)
{
    BPGEncoderParameters *parameters;
    BPGEncoderContext *encoder;
    ColorConvertState conversion;
    Image *image;
    int alpha, x, y, status;

    if (!rgba || width < 16 || height < 16 || width > 512 || height > 512 ||
        quality < 0 || quality > 100 || !write_func)
        return -1;
    alpha = 0;
    for (y = 0; y < height && !alpha; y++)
        for (x = 0; x < width; x++)
            if (rgba[(y * width + x) * 4 + 3] != 255) { alpha = 1; break; }
    parameters = bpg_encoder_param_alloc();
    if (!parameters) return -1;
    parameters->qp = (51 * (100 - quality) + 50) / 100;
    parameters->alpha_qp = 0;
    parameters->compress_level = 3;
    parameters->preferred_chroma_format = BPG_FORMAT_420;
    parameters->sei_decoded_picture_hash = 0;
    parameters->verbose = 0;
    parameters->animated = 0;
    encoder = bpg_encoder_open(parameters);
    bpg_encoder_param_free(parameters);
    if (!encoder) return -1;
    image = image_alloc(width, height, BPG_FORMAT_444, alpha, BPG_CS_YCbCr, 8);
    if (!image) { bpg_encoder_close(encoder); return -1; }
    convert_init(&conversion, 8, 8, BPG_CS_YCbCr, 0);
    for (y = 0; y < height; y++) {
        rgb24_to_ycc(&conversion,
                     (PIXEL *)(image->data[0] + y * image->linesize[0]),
                     (PIXEL *)(image->data[1] + y * image->linesize[1]),
                     (PIXEL *)(image->data[2] + y * image->linesize[2]),
                     rgba + y * width * 4, width, 4);
        if (alpha)
            gray8_to_gray(&conversion,
                          (PIXEL *)(image->data[3] + y * image->linesize[3]),
                          rgba + y * width * 4 + 3, width, 4);
    }
    /* No extension data, encoder-information SEI or camera metadata is added. */
    status = bpg_encoder_encode(encoder, image, write_func, opaque);
    image_free(image);
    bpg_encoder_close(encoder);
    return status;
}
