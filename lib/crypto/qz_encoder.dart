/// 登录加密（强智教务系统的 `encoded` 算法）
///
/// 从鸿蒙版 `crypto/QzEncoder.ets` 逐字移植。
///
/// ===== 算法说明（已对着真实响应逐字核对）=====
/// 1. 先请求 `/Logon.do?method=logon&flag=sess` 拿到握手串，形如
///    `scode#sxh`；
/// 2. `sxh` 是一串数字（至少 20 位）。把账号与密码拼成 `账号%%%密码`，
///    对第 i 个字符（i < 20）取 `sxh` 的第 i 位数字 n，
///    从 `scode` **头部切走 n 个字符**插在该字符之后，`scode` 随之变短；
/// 3. 第 20 个字符之后原样追加，不再插入；
/// 4. 提交时 `encoded` 与原始 `userPassword` **同时**发出（服务端两者都读）。
///
/// 服务端拒绝登录时握手串直接返回字面量 `no`。
library;

class QzEncoder {
  /// 构造 `encoded`。
  ///
  /// 返回空串表示握手串不合法，调用方应立即报错而不是继续提交
  /// （否则会用一个错误的 encoded 打登录接口，徒增失败次数）。
  static String buildEncoded(String sessText, String account, String password) {
    if (sessText.isEmpty) {
      return '';
    }
    final int hash = sessText.indexOf('#');
    if (hash < 0) {
      return '';
    }
    String scode = sessText.substring(0, hash);
    final String sxh = sessText.substring(hash + 1);
    // sxh 至少要能覆盖前 20 个字符
    if (scode.isEmpty || sxh.length < 20) {
      return '';
    }

    final String code = '$account%%%$password';
    final StringBuffer encoded = StringBuffer();

    for (int i = 0; i < code.length; i++) {
      if (i >= 20) {
        // 第 20 位之后原样追加
        encoded.write(code.substring(i));
        break;
      }
      final int take = int.tryParse(sxh.substring(i, i + 1)) ?? -1;
      if (take < 0) {
        return '';
      }
      String piece = '';
      if (take > 0) {
        if (take > scode.length) {
          // 握手串比预期短：按剩余全部取走，不要越界
          piece = scode;
          scode = '';
        } else {
          piece = scode.substring(0, take);
          scode = scode.substring(take);
        }
      }
      encoded.write(code.substring(i, i + 1));
      encoded.write(piece);
    }
    return encoded.toString();
  }

  /// 服务端是否拒绝了本次登录（返回字面量 `no`）
  static bool isRejected(String sessText) => sessText.trim() == 'no';

  /// 日志用：隐去 ticket，避免敏感串进日志
  static String maskTicket(String url) {
    final int i = url.indexOf('ticket=');
    if (i < 0) {
      return url;
    }
    return '${url.substring(0, i + 7)}***';
  }
}
