#include "PDFRenderer.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/print_string.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

using namespace godot;

namespace Xenu
{

PDFRenderer::PDFRenderer()
{
}

PDFRenderer::~PDFRenderer()
{
    Close();
}

bool PDFRenderer::Open(const String& path)
{
    Close();

    CharString utf8 = path.utf8();
    m_document = FPDF_LoadDocument(utf8.get_data(), nullptr);
    if (!m_document)
    {
        unsigned long err = FPDF_GetLastError();
        print_line_rich("[color=red][PDFRenderer] Failed to open PDF: " + path +
                        " (error " + String::num_int64(err) + ")[/color]");
        return false;
    }

    m_path = path;
    print_line("[PDFRenderer] Opened: " + path + " (" +
              String::num_int64(GetPageCount()) + " pages)");
    return true;
}

void PDFRenderer::Close()
{
    if (m_document)
    {
        FPDF_CloseDocument(m_document);
        m_document = nullptr;
        m_path = String();
    }
}

bool PDFRenderer::IsOpen() const
{
    return m_document != nullptr;
}

int PDFRenderer::GetPageCount() const
{
    if (!m_document)
        return 0;
    return FPDF_GetPageCount(m_document);
}

Vector2 PDFRenderer::GetPageSize(int page_index) const
{
    if (!m_document)
        return Vector2();

    double width = 0.0, height = 0.0;
    if (!FPDF_GetPageSizeByIndex(m_document, page_index, &width, &height))
        return Vector2();

    return Vector2(static_cast<float>(width), static_cast<float>(height));
}

Ref<Image> PDFRenderer::RenderPage(int page_index, int dpi) const
{
    if (!m_document)
        return Ref<Image>();

    FPDF_PAGE page = FPDF_LoadPage(m_document, page_index);
    if (!page)
    {
        print_line_rich("[color=red][PDFRenderer] Failed to load page " +
                        String::num_int64(page_index) + "[/color]");
        return Ref<Image>();
    }

    // Convert page dimensions from points (72 DPI) to pixels at requested DPI
    double width_pts = FPDF_GetPageWidth(page);
    double height_pts = FPDF_GetPageHeight(page);
    int width_px  = static_cast<int>(width_pts * dpi / 72.0);
    int height_px = static_cast<int>(height_pts * dpi / 72.0);

    if (width_px <= 0 || height_px <= 0)
    {
        FPDF_ClosePage(page);
        return Ref<Image>();
    }

    // PDFium renders to BGRA format (FPDFBitmap_BGRA = 4 bytes/pixel)
    FPDF_BITMAP bitmap = FPDFBitmap_Create(width_px, height_px, 0);
    if (!bitmap)
    {
        FPDF_ClosePage(page);
        return Ref<Image>();
    }

    // Fill with white background
    FPDFBitmap_FillRect(bitmap, 0, 0, width_px, height_px, 0xFFFFFFFF);

    // Render the page
    FPDF_RenderPageBitmap(bitmap, page, 0, 0, width_px, height_px,
                          0,  // rotation (0 = normal)
                          FPDF_ANNOT | FPDF_PRINTING);

    // Convert BGRA → RGBA for Godot
    const uint8_t* buffer = static_cast<const uint8_t*>(FPDFBitmap_GetBuffer(bitmap));
    int stride = FPDFBitmap_GetStride(bitmap);

    PackedByteArray pixels;
    pixels.resize(width_px * height_px * 4);
    uint8_t* dst = pixels.ptrw();

    for (int y = 0; y < height_px; y++)
    {
        const uint8_t* src_row = buffer + y * stride;
        uint8_t* dst_row = dst + y * width_px * 4;
        for (int x = 0; x < width_px; x++)
        {
            int si = x * 4;
            int di = x * 4;
            dst_row[di + 0] = src_row[si + 2]; // R ← B
            dst_row[di + 1] = src_row[si + 1]; // G ← G
            dst_row[di + 2] = src_row[si + 0]; // B ← R
            dst_row[di + 3] = 255;              // A = opaque
        }
    }

    FPDFBitmap_Destroy(bitmap);
    FPDF_ClosePage(page);

    Ref<Image> image = Image::create_from_data(
        width_px, height_px, false, Image::FORMAT_RGBA8, pixels);
    return image;
}

void PDFRenderer::InitLibrary()
{
    FPDF_InitLibrary();
    print_line("[PDFRenderer] PDFium library initialized.");
}

void PDFRenderer::DestroyLibrary()
{
    FPDF_DestroyLibrary();
    print_line("[PDFRenderer] PDFium library destroyed.");
}

void PDFRenderer::_bind_methods()
{
    // snake_case on the GDScript side, matching the other four first-party
    // extensions and Godot's own API. The C++ names stay PascalCase, which is
    // this file's convention — only the bound names cross the boundary.
    ClassDB::bind_method(D_METHOD("open", "path"), &PDFRenderer::Open);
    ClassDB::bind_method(D_METHOD("close"), &PDFRenderer::Close);
    ClassDB::bind_method(D_METHOD("is_open"), &PDFRenderer::IsOpen);
    ClassDB::bind_method(D_METHOD("get_page_count"), &PDFRenderer::GetPageCount);
    ClassDB::bind_method(D_METHOD("get_page_size", "page_index"), &PDFRenderer::GetPageSize);
    ClassDB::bind_method(D_METHOD("render_page", "page_index", "dpi"), &PDFRenderer::RenderPage,
                         DEFVAL(150));
}

}
