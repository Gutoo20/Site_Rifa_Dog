<%@ WebHandler Language="C#" Class="AdminApi" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web;

public class AdminApi : IHttpHandler
{
    const string NomeCookie = "rifa_adm";
    const int MaxFalhas = 5;
    static readonly TimeSpan Bloqueio = TimeSpan.FromMinutes(15);
    static readonly TimeSpan DuracaoSessao = TimeSpan.FromHours(2);

    class Tentativa { public int Falhas; public DateTime BloqueadoAte; }

    // Sessoes e tentativas ficam em memoria (reiniciar o app pool exige novo login)
    static readonly object TravaSessao = new object();
    static readonly Dictionary<string, DateTime> Sessoes = new Dictionary<string, DateTime>();
    static readonly Dictionary<string, Tentativa> Tentativas = new Dictionary<string, Tentativa>();

    public bool IsReusable { get { return false; } }

    static string Cfg(string chave) { return ConfigurationManager.AppSettings[chave] ?? ""; }

    public void ProcessRequest(HttpContext ctx)
    {
        var r = ctx.Response;
        r.ContentType = "application/json";
        r.ContentEncoding = Encoding.UTF8;
        r.Cache.SetCacheability(HttpCacheability.NoCache);
        r.AppendHeader("X-Content-Type-Options", "nosniff");
        r.AppendHeader("X-Frame-Options", "DENY");

        try
        {
            string acao = ctx.Request.QueryString["action"] ?? "";
            bool post = ctx.Request.HttpMethod == "POST";

            if (Cfg("AdminSenha").Length == 0 || Cfg("AdminUsuario").Length == 0)
            {
                Erro(ctx, 503, "Area administrativa desativada (AdminUsuario/AdminSenha nao configurados).");
                return;
            }

            // Protecao CSRF: POST so aceito com cabecalho que formularios de outros sites nao conseguem enviar
            if (post && ctx.Request.Headers["X-Requested-With"] != "XMLHttpRequest")
            {
                Erro(ctx, 400, "Requisicao invalida.");
                return;
            }

            if (post && acao == "login") { Login(ctx); return; }
            if (!post && acao == "sessao") { r.Write("{\"ok\":true,\"autenticado\":" + (Autenticado(ctx) ? "true" : "false") + "}"); return; }

            if (!Autenticado(ctx)) { Erro(ctx, 401, "Nao autenticado."); return; }

            if (!post && acao == "lista") Lista(ctx);
            else if (!post && acao == "comprovante") Comprovante(ctx);
            else if (post && acao == "liberar") Liberar(ctx);
            else if (post && acao == "logout") Logout(ctx);
            else Erro(ctx, 400, "Requisicao invalida.");
        }
        catch (Exception ex)
        {
            System.Diagnostics.Trace.TraceError(ex.ToString());
            if (ctx.Response.ContentType == "application/json")
                Erro(ctx, 500, "Erro interno.");
        }
    }

    // ---------- autenticacao ----------
    void Login(HttpContext ctx)
    {
        string ip = ctx.Request.UserHostAddress ?? "?";
        DateTime agora = DateTime.UtcNow;

        lock (TravaSessao)
        {
            Tentativa t;
            if (Tentativas.TryGetValue(ip, out t) && t.BloqueadoAte > agora)
            {
                Erro(ctx, 429, "Muitas tentativas. Aguarde alguns minutos.");
                return;
            }
        }

        string usuarioInformado = ctx.Request.Form["usuario"] ?? "";
        string informada = ctx.Request.Form["senha"] ?? "";
        // '&' (e nao '&&') para sempre comparar os dois e nao revelar qual campo errou
        bool credenciaisOk = SenhaConfere(usuarioInformado, Cfg("AdminUsuario")) & SenhaConfere(informada, Cfg("AdminSenha"));
        if (!credenciaisOk)
        {
            lock (TravaSessao)
            {
                Tentativa t;
                if (!Tentativas.TryGetValue(ip, out t)) { t = new Tentativa(); Tentativas[ip] = t; }
                t.Falhas++;
                if (t.Falhas >= MaxFalhas) { t.BloqueadoAte = agora + Bloqueio; t.Falhas = 0; }
            }
            Thread.Sleep(700); // desacelera tentativas automatizadas
            Erro(ctx, 401, "Usuario ou senha incorretos.");
            return;
        }

        string token = NovoToken();
        lock (TravaSessao)
        {
            Tentativas.Remove(ip);
            LimparSessoesExpiradas();
            Sessoes[token] = agora + DuracaoSessao;
        }
        DefinirCookie(ctx, token, (int)DuracaoSessao.TotalSeconds);
        ctx.Response.Write("{\"ok\":true}");
    }

    void Logout(HttpContext ctx)
    {
        HttpCookie c = ctx.Request.Cookies[NomeCookie];
        if (c != null) lock (TravaSessao) { Sessoes.Remove(c.Value); }
        DefinirCookie(ctx, "", 0);
        ctx.Response.Write("{\"ok\":true}");
    }

    static bool Autenticado(HttpContext ctx)
    {
        HttpCookie c = ctx.Request.Cookies[NomeCookie];
        if (c == null || string.IsNullOrEmpty(c.Value)) return false;
        lock (TravaSessao)
        {
            DateTime ate;
            if (!Sessoes.TryGetValue(c.Value, out ate)) return false;
            if (ate < DateTime.UtcNow) { Sessoes.Remove(c.Value); return false; }
            return true;
        }
    }

    static void LimparSessoesExpiradas()
    {
        DateTime agora = DateTime.UtcNow;
        foreach (string k in Sessoes.Where(p => p.Value < agora).Select(p => p.Key).ToList())
            Sessoes.Remove(k);
    }

    // HttpOnly + SameSite=Strict (+ Secure quando em HTTPS). Montado a mao porque o .NET 4.0 nao tem SameSite.
    static void DefinirCookie(HttpContext ctx, string valor, int segundos)
    {
        string path = ctx.Request.ApplicationPath;
        if (string.IsNullOrEmpty(path)) path = "/";
        string c = NomeCookie + "=" + valor + "; Path=" + path + "; HttpOnly; SameSite=Strict";
        if (segundos > 0) c += "; Max-Age=" + segundos; else c += "; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT";
        if (ctx.Request.IsSecureConnection) c += "; Secure";
        ctx.Response.AppendHeader("Set-Cookie", c);
    }

    static string NovoToken()
    {
        var b = new byte[32];
        using (var rng = new RNGCryptoServiceProvider()) rng.GetBytes(b);
        return BitConverter.ToString(b).Replace("-", "").ToLowerInvariant();
    }

    // Comparacao em tempo constante (compara hashes SHA-256)
    static bool SenhaConfere(string a, string b)
    {
        using (var sha = SHA256.Create())
        {
            byte[] ha = sha.ComputeHash(Encoding.UTF8.GetBytes(a));
            byte[] hb = sha.ComputeHash(Encoding.UTF8.GetBytes(b));
            int dif = 0;
            for (int i = 0; i < ha.Length; i++) dif |= ha[i] ^ hb[i];
            return dif == 0;
        }
    }

    // ---------- GET lista ----------
    void Lista(HttpContext ctx)
    {
        List<Compra> compras;
        List<int> vendidos;
        lock (RifaDados.Trava)
        {
            compras = RifaDados.LerCompras(ctx);
            vendidos = RifaDados.LerVendidos(ctx);
        }

        string pasta = RifaDados.PastaComprovantes(ctx);
        var sb = new StringBuilder();
        sb.Append("{\"ok\":true");
        sb.Append(",\"total\":").Append(ConfigurationManager.AppSettings["TotalNumeros"]);
        sb.Append(",\"vendidos\":").Append(vendidos.Count);
        sb.Append(",\"compras\":[");
        bool primeiro = true;
        foreach (Compra c in compras.OrderByDescending(x => x.Data))
        {
            if (!primeiro) sb.Append(",");
            primeiro = false;
            bool temArq = !string.IsNullOrEmpty(c.Arquivo) && File.Exists(Path.Combine(pasta, Path.GetFileName(c.Arquivo)));
            sb.Append("{\"id\":").Append(RifaDados.Js(c.Id));
            sb.Append(",\"data\":").Append(RifaDados.Js(c.Data.ToString("dd/MM/yyyy HH:mm:ss", CultureInfo.InvariantCulture)));
            sb.Append(",\"nome\":").Append(RifaDados.Js(c.Nome));
            sb.Append(",\"contato\":").Append(RifaDados.Js(c.Contato));
            sb.Append(",\"numeros\":[").Append(RifaDados.ListaNum(c.Numeros));
            sb.Append("],\"temComprovante\":").Append(temArq ? "true" : "false").Append("}");
        }
        sb.Append("]}");
        ctx.Response.Write(sb.ToString());
    }

    // ---------- GET comprovante ----------
    void Comprovante(HttpContext ctx)
    {
        string id = ctx.Request.QueryString["id"];
        if (!RifaDados.IdValido(id)) { Erro(ctx, 400, "Id invalido."); return; }

        Compra c;
        lock (RifaDados.Trava) { c = RifaDados.LerCompras(ctx).FirstOrDefault(x => x.Id == id); }
        if (c == null || string.IsNullOrEmpty(c.Arquivo)) { Erro(ctx, 404, "Comprovante nao encontrado."); return; }

        string nomeArq = Path.GetFileName(c.Arquivo); // impede path traversal
        string caminho = Path.Combine(RifaDados.PastaComprovantes(ctx), nomeArq);
        if (!File.Exists(caminho)) { Erro(ctx, 404, "Comprovante nao encontrado."); return; }

        string ext = Path.GetExtension(nomeArq).ToLowerInvariant();
        string mime = ext == ".pdf" ? "application/pdf" : ext == ".png" ? "image/png" : ext == ".jpg" ? "image/jpeg" : null;
        if (mime == null) { Erro(ctx, 404, "Comprovante nao encontrado."); return; }

        ctx.Response.ContentType = mime;
        ctx.Response.AppendHeader("Content-Disposition", "inline; filename=comprovante" + ext);
        ctx.Response.AppendHeader("Content-Security-Policy", "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; sandbox");
        ctx.Response.Cache.SetCacheability(HttpCacheability.Private);
        ctx.Response.WriteFile(caminho);
    }

    // ---------- POST liberar ----------
    void Liberar(HttpContext ctx)
    {
        string id = ctx.Request.Form["id"];
        if (!RifaDados.IdValido(id)) { Erro(ctx, 400, "Id invalido."); return; }

        var pedidos = new List<int>();
        foreach (string s in (ctx.Request.Form["numeros"] ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
        {
            int n;
            if (!int.TryParse(s.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out n)) { Erro(ctx, 400, "Numero invalido."); return; }
            if (!pedidos.Contains(n)) pedidos.Add(n);
        }
        if (pedidos.Count == 0) { Erro(ctx, 400, "Selecione ao menos um numero."); return; }

        lock (RifaDados.Trava)
        {
            List<Compra> compras = RifaDados.LerCompras(ctx);
            Compra c = compras.FirstOrDefault(x => x.Id == id);
            if (c == null) { Erro(ctx, 404, "Compra nao encontrada."); return; }

            // So libera numeros que realmente pertencem a essa compra
            if (pedidos.Any(n => !c.Numeros.Contains(n))) { Erro(ctx, 400, "Numero nao pertence a esta compra."); return; }

            List<int> vendidos = RifaDados.LerVendidos(ctx);
            vendidos.RemoveAll(n => pedidos.Contains(n));
            c.Numeros.RemoveAll(n => pedidos.Contains(n));

            RifaDados.GravarVendidos(ctx, vendidos);
            RifaDados.GravarCompras(ctx, compras);
            RifaDados.RegistrarLiberacao(ctx, "ip=" + ctx.Request.UserHostAddress + " compra=" + c.Id + " (" + c.Nome + ") numeros=" + RifaDados.ListaNum(pedidos));
        }

        ctx.Response.Write("{\"ok\":true}");
    }

    static void Erro(HttpContext ctx, int status, string mensagem)
    {
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        ctx.Response.Write("{\"ok\":false,\"erro\":" + RifaDados.Js(mensagem) + "}");
    }
}
