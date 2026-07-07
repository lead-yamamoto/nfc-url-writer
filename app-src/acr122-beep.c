/*
 * acr122-beep.c — ACR122U のブザー(ピッ音)を制御する小さな libusb ヘルパ。
 *
 * 背景:
 *   ACR122U は「カード検出時のブザー」設定をファームウェアに保持している。
 *   これが macOS の PC/SC スタックに触られて OFF のまま残ることがある。
 *   libnfc にはこのベンダ APDU を送る API が無いため、libusb で直接
 *   ACR122U(VID 0x072F, PID 0x2200/0x2214)を掴み、CCID の
 *   PC_to_RDR_XfrBlock フレームに擬似 APDU を載せて送る。
 *
 * 使い方:
 *   acr122-beep enable   … カード検出時のブザーを常時 ON に戻す (FF 00 52 FF 00)
 *   acr122-beep beep     … 明示的に1回鳴らす            (FF 00 40 00 04 01 00 01 01)
 *
 * 終了コード:
 *   0  = 成功(APDU 送信し応答を受領)
 *   1  = リーダー未検出 / 使用中 / 送信失敗(呼び出し側は無視してよい=ベストエフォート)
 *   2  = 引数エラー
 *
 * 注意:
 *   libnfc がデバイスを掴んでいる間は claim に失敗する。必ず nfc 系サブプロセスの
 *   合間/完了後に実行すること。エンドポイントはインタフェース記述子から動的に
 *   列挙する(ハードコードしない)。
 *
 * ビルド(pkg-config が無くても可):
 *   clang acr122-beep.c -I<libusb prefix>/include -L<libusb prefix>/lib -lusb-1.0 -o acr122-beep
 */
#include <libusb-1.0/libusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ACR122U / 一般的な ACS リーダーの USB ID。*/
#define ACS_VID        0x072F
#define ACR122U_PID_A  0x2200
#define ACR122U_PID_B  0x2214

/* CCID PC_to_RDR_XfrBlock メッセージタイプ。*/
#define CCID_XFRBLOCK  0x6F

/* ブザー再有効化: カード検出時ブザーを ON(=0xFF)。*/
static const uint8_t APDU_ENABLE[] = { 0xFF, 0x00, 0x52, 0xFF, 0x00 };
/* 明示ブザー: T=0x01 x 0x00 回, ブザー ON 0x01 / OFF 0x00 の指定で1回鳴らす。*/
static const uint8_t APDU_BEEP[]   = { 0xFF, 0x00, 0x40, 0x00, 0x04, 0x01, 0x00, 0x01, 0x01 };

/* 送受信のタイムアウト(ミリ秒)。*/
#define USB_TIMEOUT_MS 1000

/* CCID XfrBlock フレームを組み立てて bulk-OUT に送り、bulk-IN で応答を受ける。
 * 成功したら 0、失敗したら非0 を返す。*/
static int send_apdu(libusb_device_handle *h,
                     unsigned char ep_out, unsigned char ep_in,
                     const uint8_t *apdu, int apdu_len)
{
    /* 10 バイトの CCID ヘッダ + APDU 本体。*/
    uint8_t frame[10 + 64];
    if (apdu_len < 0 || apdu_len > (int)sizeof(frame) - 10) return -1;

    memset(frame, 0, sizeof(frame));
    frame[0] = CCID_XFRBLOCK;               /* bMessageType = PC_to_RDR_XfrBlock */
    /* bytes1-4: dwLength (APDU 長) をリトルエンディアンで。*/
    frame[1] = (uint8_t)(apdu_len & 0xFF);
    frame[2] = (uint8_t)((apdu_len >> 8) & 0xFF);
    frame[3] = (uint8_t)((apdu_len >> 16) & 0xFF);
    frame[4] = (uint8_t)((apdu_len >> 24) & 0xFF);
    frame[5] = 0x00;                        /* bSlot */
    frame[6] = 0x00;                        /* bSeq  */
    frame[7] = 0x00;                        /* abRFU */
    frame[8] = 0x00;
    frame[9] = 0x00;
    memcpy(frame + 10, apdu, (size_t)apdu_len);

    int total = 10 + apdu_len;
    int transferred = 0;
    int rc = libusb_bulk_transfer(h, ep_out, frame, total, &transferred, USB_TIMEOUT_MS);
    if (rc != 0) {
        fprintf(stderr, "acr122-beep: bulk-out 失敗: %s\n", libusb_error_name(rc));
        return -1;
    }

    /* 応答(CCID RDR_to_PC_DataBlock)を読む。無くても致命的ではないが、
     * リーダーが応答したことを確認するため best-effort で受ける。*/
    uint8_t resp[64];
    int rlen = 0;
    rc = libusb_bulk_transfer(h, ep_in, resp, (int)sizeof(resp), &rlen, USB_TIMEOUT_MS);
    if (rc != 0) {
        /* 応答が取れなくても送信自体は成功しているので警告のみ。*/
        fprintf(stderr, "acr122-beep: 応答読み取り警告: %s\n", libusb_error_name(rc));
    }
    return 0;
}

/* インタフェース記述子から bulk IN/OUT エンドポイントアドレスを列挙する。
 * 見つかったら ep_out / ep_in にセットして 0、無ければ非0。*/
static int find_bulk_endpoints(libusb_device *dev, int *iface_out,
                               unsigned char *ep_out, unsigned char *ep_in)
{
    struct libusb_config_descriptor *cfg = NULL;
    if (libusb_get_active_config_descriptor(dev, &cfg) != 0 || cfg == NULL)
        return -1;

    int found = -1;
    for (int i = 0; i < cfg->bNumInterfaces && found != 0; i++) {
        const struct libusb_interface *itf = &cfg->interface[i];
        for (int a = 0; a < itf->num_altsetting; a++) {
            const struct libusb_interface_descriptor *id = &itf->altsetting[a];
            unsigned char o = 0, in = 0;
            int have_o = 0, have_in = 0;
            for (int e = 0; e < id->bNumEndpoints; e++) {
                const struct libusb_endpoint_descriptor *ep = &id->endpoint[e];
                int is_bulk = (ep->bmAttributes & 0x03) == LIBUSB_TRANSFER_TYPE_BULK;
                if (!is_bulk) continue;
                if (ep->bEndpointAddress & 0x80) { in = ep->bEndpointAddress; have_in = 1; }
                else                              { o  = ep->bEndpointAddress; have_o  = 1; }
            }
            if (have_o && have_in) {
                *iface_out = id->bInterfaceNumber;
                *ep_out = o;
                *ep_in  = in;
                found = 0;
                break;
            }
        }
    }
    libusb_free_config_descriptor(cfg);
    return found;
}

int main(int argc, char **argv)
{
    if (argc != 2 || (strcmp(argv[1], "enable") != 0 && strcmp(argv[1], "beep") != 0)) {
        fprintf(stderr, "使い方: acr122-beep enable|beep\n");
        return 2;
    }
    const uint8_t *apdu;
    int apdu_len;
    if (strcmp(argv[1], "enable") == 0) {
        apdu = APDU_ENABLE; apdu_len = (int)sizeof(APDU_ENABLE);
    } else {
        apdu = APDU_BEEP;   apdu_len = (int)sizeof(APDU_BEEP);
    }

    libusb_context *ctx = NULL;
    if (libusb_init(&ctx) != 0) {
        fprintf(stderr, "acr122-beep: libusb 初期化に失敗しました。\n");
        return 1;
    }

    libusb_device **list = NULL;
    ssize_t n = libusb_get_device_list(ctx, &list);
    if (n < 0) {
        fprintf(stderr, "acr122-beep: USB デバイス列挙に失敗しました。\n");
        libusb_exit(ctx);
        return 1;
    }

    int rc_final = 1;   /* 既定は失敗(リーダー未検出)。*/
    for (ssize_t i = 0; i < n; i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(list[i], &d) != 0) continue;
        if (d.idVendor != ACS_VID) continue;
        if (d.idProduct != ACR122U_PID_A && d.idProduct != ACR122U_PID_B) continue;

        int iface = 0;
        unsigned char ep_out = 0, ep_in = 0;
        if (find_bulk_endpoints(list[i], &iface, &ep_out, &ep_in) != 0) {
            fprintf(stderr, "acr122-beep: bulk エンドポイントが見つかりません。\n");
            continue;
        }

        libusb_device_handle *h = NULL;
        if (libusb_open(list[i], &h) != 0 || h == NULL) {
            fprintf(stderr, "acr122-beep: リーダーを開けません(使用中の可能性)。\n");
            continue;
        }

        /* macOS のカーネルドライバが掴んでいる場合は外す(取れなくても続行)。*/
        libusb_set_auto_detach_kernel_driver(h, 1);

        int claimed = libusb_claim_interface(h, iface);
        if (claimed != 0) {
            fprintf(stderr, "acr122-beep: インタフェース claim 失敗: %s(libnfc/PCSC が使用中の可能性)。\n",
                    libusb_error_name(claimed));
            libusb_close(h);
            continue;
        }

        if (send_apdu(h, ep_out, ep_in, apdu, apdu_len) == 0) {
            rc_final = 0;
        }

        libusb_release_interface(h, iface);
        libusb_close(h);
        break;   /* 最初に見つかった ACR122U を処理したら終了。*/
    }

    libusb_free_device_list(list, 1);
    libusb_exit(ctx);
    return rc_final;
}
