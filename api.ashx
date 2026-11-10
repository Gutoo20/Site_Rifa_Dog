<%@ WebHandler Language="C#" Class="RifaApi" %>

using System;
using System.Collections.Generic;
using System.Configuration;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Mail;
using System.Text;
using System.Web;

public class RifaApi : IHttpHandler
{
    public bool IsReusable { get { return false; } }

    static string Cfg(string chave)
    {
        return ConfigurationManager.AppSettings[chave] ?? "";
    }

    static int Total { get { return int.Parse(Cfg("TotalNumeros"), CultureInfo.InvariantCulture); } }
    static decimal Valor { get { return decimal.Parse(Cfg("ValorNumero"), CultureInfo.InvariantCulture); } }

    public void ProcessRequest(HttpContext ctx)
    {
        ctx.Response.ContentType = "application/json";
        ctx.Response.ContentEncoding = Encoding.UTF8;
        ctx.Response.Cache.SetCacheability(HttpCacheability.NoCache);

        try
        {
            string acao = ctx.Request.QueryString["action"] ?? "";
            if (ctx.Request.HttpMethod == "GET" && acao == "status")
                Status(ctx);
            else if (ctx.Request.HttpMethod == "POST" && acao == "comprar")
                Comprar(ctx);
            else
                Erro(ctx, 400, "Requisicao invalida.");
        }
        catch (Exception ex)
        {
            // Detalhes apenas no log do servidor
            System.Diagnostics.Trace.TraceError(ex.ToString());
            Erro(ctx, 500, "Erro interno. Tente novamente em instantes.");
        }
    }

    // ---------- GET status ----------
    void Status(HttpContext ctx)
    {
        List<int> vendidos;
        lock (RifaDados.Trava) { vendidos = RifaDados.LerVendidos(ctx); }

        var sb = new StringBuilder();
        sb.Append("{\"ok\":true");
        sb.Append(",\"nome\":").Append(RifaDados.Js(Cfg("NomeRifa")));
        sb.Append(",\"total\":").Append(Total);
        sb.Append(",\"valor\":").Append(Valor.ToString(CultureInfo.InvariantCulture));
        sb.Append(",\"favorecido\":").Append(RifaDados.Js(Cfg("Favorecido")));
        sb.Append(",\"chavePix\":").Append(RifaDados.Js(Cfg("ChavePix")));
        sb.Append(",\"instrucoes\":").Append(RifaDados.Js(Cfg("InstrucoesPagamento")));
        sb.Append(",\"vendidos\":[").Append(RifaDados.ListaNum(vendidos)).Append("]}");
        ctx.Response.Write(sb.ToString());
    }

    // ---------- POST comprar ----------
    void Comprar(HttpContext ctx)
    {
        // Numeros escolhidos
        var escolhidos = new List<int>();
        foreach (string parte in (ctx.Request.Form["numeros"] ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
        {
            int n;
            if (!int.TryParse(parte.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out n) || n < 1 || n > Total)
            {
                Erro(ctx, 400, "Numero invalido.");
                return;
            }
            if (!escolhidos.Contains(n)) escolhidos.Add(n);
        }
        if (escolhidos.Count == 0) { Erro(ctx, 400, "Selecione ao menos um numero."); return; }
        escolhidos.Sort();

        // Comprador
        string nome = (ctx.Request.Form["nome"] ?? "").Trim();
        string contato = (ctx.Request.Form["contato"] ?? "").Trim();
        if (nome.Length == 0 || nome.Length > 100) { Erro(ctx, 400, "Informe seu nome (ate 100 caracteres)."); return; }
        if (contato.Length > 60) { Erro(ctx, 400, "Contato muito longo."); return; }

        // Comprovante
        HttpPostedFile arq = ctx.Request.Files["comprovante"];
        if (arq == null || arq.ContentLength == 0) { Erro(ctx, 400, "Anexe o comprovante de pagamento."); return; }
        if (arq.ContentLength > 5 * 1024 * 1024) { Erro(ctx, 400, "Comprovante maior que 5 MB."); return; }

        byte[] bytes = new byte[arq.ContentLength];
        int lidos = 0;
        while (lidos < bytes.Length)
        {
            int r = arq.InputStream.Read(bytes, lidos, bytes.Length - lidos);
            if (r <= 0) break;
            lidos += r;
        }

        string ext, mime;
        if (!DetectarTipo(bytes, out ext, out mime))
        {
            Erro(ctx, 400, "Formato de comprovante nao aceito. Envie JPG, PNG ou PDF.");
            return;
        }

        lock (RifaDados.Trava)
        {
            // Rechecagem final: alguem pode ter comprado enquanto o usuario pagava
            List<int> vendidos = RifaDados.LerVendidos(ctx);
            List<int> conflitos = escolhidos.Where(n => vendidos.Contains(n)).ToList();
            if (conflitos.Count > 0)
            {
                ctx.Response.StatusCode = 409;
                ctx.Response.Write("{\"ok\":false,\"erro\":" + RifaDados.Js("Alguns numeros ja foram reservados por outra pessoa.")
                    + ",\"conflitos\":[" + RifaDados.ListaNum(conflitos) + "]}");
                return;
            }

            // Guarda o comprovante (nome gerado pelo servidor, nunca o enviado pelo usuario)
            string id = Guid.NewGuid().ToString("N");
            string nomeArquivo = id + ext;
            string caminhoArquivo = Path.Combine(RifaDados.PastaComprovantes(ctx), nomeArquivo);
            File.WriteAllBytes(caminhoArquivo, bytes);

            // Primeiro envia o e-mail; so trava os numeros se o envio der certo
            try
            {
                EnviarEmail(nome, contato, escolhidos, bytes, "comprovante" + ext, mime);
            }
            catch
            {
                try { File.Delete(caminhoArquivo); } catch { }
                throw;
            }

            RifaDados.AdicionarVendidos(ctx, escolhidos);
            RifaDados.AdicionarCompra(ctx, new Compra
            {
                Id = id,
                Data = DateTime.Now,
                Nome = nome,
                Contato = contato,
                Numeros = escolhidos,
                Arquivo = nomeArquivo
            });
        }

        ctx.Response.Write("{\"ok\":true}");
    }

    void EnviarEmail(string nome, string contato, List<int> numeros, byte[] arquivo, string nomeArquivo, string mime)
    {
        string usuario = Cfg("SmtpUsuario");
        string remetente = Cfg("EmailRemetente");
        if (remetente.Length == 0) remetente = usuario;
        if (Cfg("SmtpHost").Length == 0 || remetente.Length == 0)
            throw new InvalidOperationException("SMTP nao configurado no web.config.");

        decimal total = numeros.Count * Valor;
        var corpo = new StringBuilder();
        corpo.AppendLine("Nova compra de rifa");
        corpo.AppendLine();
        corpo.AppendLine("Nome: " + RifaDados.Limpa(nome));
        corpo.AppendLine("Contato: " + (contato.Length == 0 ? "(nao informado)" : RifaDados.Limpa(contato)));
        corpo.AppendLine("Numeros: " + string.Join(", ", numeros.Select(n => RifaDados.Num(n)).ToArray()));
        corpo.AppendLine("Quantidade: " + numeros.Count);
        corpo.AppendLine("Valor total: R$ " + total.ToString("N2", new CultureInfo("pt-BR")));
        corpo.AppendLine("Data: " + DateTime.Now.ToString("dd/MM/yyyy HH:mm:ss"));

        using (var msg = new MailMessage())
        using (var anexo = new Attachment(new MemoryStream(arquivo), nomeArquivo, mime))
        {
            msg.From = new MailAddress(remetente);
            msg.To.Add(new MailAddress(Cfg("EmailDestino")));
            msg.Subject = "Rifa - numeros " + string.Join(", ", numeros.Select(n => RifaDados.Num(n)).ToArray());
            msg.Body = corpo.ToString();
            msg.BodyEncoding = Encoding.UTF8;
            msg.SubjectEncoding = Encoding.UTF8;
            msg.Attachments.Add(anexo);

            using (var smtp = new SmtpClient(Cfg("SmtpHost"), int.Parse(Cfg("SmtpPort"), CultureInfo.InvariantCulture)))
            {
                smtp.EnableSsl = string.Equals(Cfg("SmtpSsl"), "true", StringComparison.OrdinalIgnoreCase);
                smtp.Timeout = 30000;
                if (usuario.Length > 0)
                    smtp.Credentials = new NetworkCredential(usuario, Cfg("SmtpSenha"));
                smtp.Send(msg);
            }
        }
    }

    // Valida pelo conteudo real do arquivo (nao confia na extensao enviada)
    static bool DetectarTipo(byte[] b, out string ext, out string mime)
    {
        ext = null; mime = null;
        if (b.Length > 4 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) { ext = ".jpg"; mime = "image/jpeg"; return true; }
        if (b.Length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) { ext = ".png"; mime = "image/png"; return true; }
        if (b.Length > 5 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46 && b[4] == 0x2D) { ext = ".pdf"; mime = "application/pdf"; return true; }
        return false;
    }

    static void Erro(HttpContext ctx, int status, string mensagem)
    {
        ctx.Response.StatusCode = status;
        ctx.Response.Write("{\"ok\":false,\"erro\":" + RifaDados.Js(mensagem) + "}");
    }
}
