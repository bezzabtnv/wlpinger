unit Unit1;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  System.Net.HttpClient, System.Net.URLClient, System.Diagnostics,
  System.IOUtils, System.Threading, System.SyncObjs,
  {$IF DEFINED(ANDROID)}
  Androidapi.Helpers, Androidapi.JNI.Net, Androidapi.JNIBridge, Androidapi.JNI.Os,
  Androidapi.JNI.GraphicsContentViewText, Androidapi.JNI.Webkit, Androidapi.JNI.JavaTypes,
  {$ENDIF}
  {$IF DEFINED(MSWINDOWS)}
  Winapi.Windows, Vcl.Clipbrd,
  {$ENDIF}
  {$IF DEFINED(MACOS)}
  Macapi.CoreFoundation, Macapi.CocoaTypes, Macapi.Foundation, Macapi.AppKit,
  {$ENDIF}
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs,
  FMX.Controls.Presentation, FMX.ScrollBox, FMX.Memo, FMX.StdCtrls,
  FMX.Layouts, FMX.Edit, FMX.Memo.Types, FMX.Objects, FMX.Gestures,
  FMX.Platform, FMX.Clipboard;

type
  TPingResult = record
    Host: string;
    AvgPing: Integer;
    Status: string;
    Index: Integer;
  end;

  TForm1 = class(TForm)
    LabelURL: TLabel;
    edtURL: TEdit;
    btnLoadURL: TButton;
    btnStart: TButton;
    btnStop: TButton;
    lblStatus: TLabel;
    ProgressBar1: TProgressBar;
    LabelList: TLabel;
    MemoList: TMemo;
    LabelLog: TLabel;
    MemoLog: TMemo;
    StyleBook1: TStyleBook;
    btnClearList: TButton;
    Panel1: TPanel;
    Image1: TImage;
    CheckBox1: TCheckBox;
    btnPasteFromClipboard: TButton;
    info: TButton;

    procedure btnStartClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnLoadURLClick(Sender: TObject);
    procedure MemoListChange(Sender: TObject);
    procedure btnClearListClick(Sender: TObject);
    procedure Image1Click(Sender: TObject);
    procedure edtURLDblClick(Sender: TObject);
    procedure btnPasteFromClipboardClick(Sender: TObject);
    procedure infoClick(Sender: TObject);
  private
    FIsRunning: Boolean;
    FCancelled: Boolean;
    FHosts: TStringList;
    FTimeoutMs: Integer;
    FCompletedCount: Integer;
    FSuccessCount: Integer;
    FTotalCount: Integer;
    FPingThread: TThread;

    procedure LogMessage(const Msg: string);
    procedure UpdateProgress;
    function PingHost(const Host: string): TPingResult;
    procedure LoadWhitelistFromString(const Content: string);
    procedure LoadWhitelistFromURL(const URL: string);
    procedure RunPingTest;
    procedure OnPingComplete;
    procedure UpdateHostsFromMemo;
    procedure ShowToast(const Msg: string);
    procedure PasteFromClipboardToMemo;
    procedure SetRunningState(const ARunning: Boolean);
    procedure ApplyResultsToMemo;
  public
    { Public declarations }
  end;

var
  Form1: TForm1;
  {$IF DEFINED(ANDROID)}
  OpenLinkIntent: JIntent;
  {$ENDIF}

implementation

{$R *.fmx}
{$R *.LgXhdpiTb.fmx ANDROID}
{$R *.SmXhdpiPh.fmx ANDROID}
{$R *.LgXhdpiPh.fmx ANDROID}
{$R *.XLgXhdpiTb.fmx ANDROID}
{$R *.NmXhdpiPh.fmx ANDROID}

const
  // Сколько хостов проверяем параллельно (подберите под устройство: 4–16)
  MAX_PARALLEL_CHECKS = 8;
  // Таймауты
  TIMEOUT_FAST_MS = 800;
  TIMEOUT_NORMAL_MS = 2500;

procedure TForm1.FormCreate(Sender: TObject);
begin
  FHosts := TStringList.Create;
  FIsRunning := False;
  FCancelled := False;
  FCompletedCount := 0;
  FSuccessCount := 0;
  FTotalCount := 0;
  FTimeoutMs := TIMEOUT_NORMAL_MS;

  btnStop.Enabled := False;
  btnClearList.Enabled := True;
  ProgressBar1.Value := 0;
  lblStatus.Text := '';

  edtURL.Text := 'https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main/whitelist.txt';

  MemoList.Text := '';
  MemoList.ReadOnly := False;
  MemoList.ShowHint := True;
  MemoList.Hint := 'Введите хосты (каждый с новой строки)';

  MemoLog.ReadOnly := True;
  LogMessage('Приложение запущено');
  LogMessage('Введите URL и нажмите "Загрузить" или введите хосты вручную или из буфера обмена.');
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  FCancelled := True;
  if Assigned(FPingThread) then
  begin
    FPingThread.FreeOnTerminate := False;
    // Не ждём через WaitFor, чтобы не зависнуть при выходе — просто отпускаем
    FPingThread.Free;
    FPingThread := nil;
  end;
  FHosts.Free;
end;

procedure TForm1.SetRunningState(const ARunning: Boolean);
begin
  FIsRunning := ARunning;
  btnStart.Enabled := not ARunning;
  btnLoadURL.Enabled := not ARunning;
  btnClearList.Enabled := not ARunning;
  btnPasteFromClipboard.Enabled := not ARunning;
  btnStop.Enabled := ARunning;
end;

procedure TForm1.Image1Click(Sender: TObject);
begin
{$IF DEFINED(ANDROID)}
  OpenLinkIntent := TJIntent.JavaClass.init(TJIntent.JavaClass.ACTION_VIEW);
  OpenLinkIntent.setData(StrToJURI('https://tips.yandex.ru/guest/payment/7496710'));
  SharedActivity.startActivity(OpenLinkIntent);
{$ENDIF}
end;

procedure TForm1.infoClick(Sender: TObject);
begin
  ShowMessage('WL pinger. Программа для проверки доступности хостов. Разработчик Олег Беззаботнов.');
end;

procedure TForm1.ShowToast(const Msg: string);
begin
  LogMessage(Msg);
end;

procedure TForm1.LogMessage(const Msg: string);
begin
  if TThread.CurrentThread.ThreadID = MainThreadID then
  begin
    MemoLog.Lines.Add(Format('[%s] %s', [FormatDateTime('hh:nn:ss', Now), Msg]));
    MemoLog.GoToTextEnd;
  end
  else
  begin
    TThread.Queue(nil,
      procedure
      begin
        MemoLog.Lines.Add(Format('[%s] %s', [FormatDateTime('hh:nn:ss', Now), Msg]));
        MemoLog.GoToTextEnd;
      end
    );
  end;
end;

procedure TForm1.UpdateProgress;
var
  C, T: Integer;
  Pct: Double;
begin
  C := FCompletedCount;
  T := FTotalCount;
  if T <= 0 then
    Exit;
  Pct := (C / T) * 100;
  ProgressBar1.Value := Pct;
  lblStatus.Text := Format('%d/%d (%.1f%%)  OK: %d', [C, T, Pct, FSuccessCount]);
end;

function TForm1.PingHost(const Host: string): TPingResult;
var
  HTTP: THTTPClient;
  Response: IHTTPResponse;
  Stopwatch: TStopwatch;
  Endpoints: TArray<string>;
  j: Integer;
  BestPing: Integer;
  Url: string;
begin
  Result.Host := Host;
  Result.AvgPing := 9999;
  Result.Status := 'TIMEOUT';

  // Два эндпоинта вместо четырёх — покрытие почти то же, но в 2 раза быстрее
  Endpoints := TArray<string>.Create('/', '/favicon.ico');

  HTTP := THTTPClient.Create;
  try
    HTTP.ResponseTimeout := FTimeoutMs;
    HTTP.ConnectionTimeout := FTimeoutMs;
    HTTP.UserAgent := 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';

    BestPing := MaxInt;

    for j := 0 to Length(Endpoints) - 1 do
    begin
      if FCancelled then
        Break;

      // Сначала HEAD (быстро, без тела), если не вышло — GET
      Url := 'https://' + Host + Endpoints[j];
      try
        Stopwatch := TStopwatch.StartNew;
        Response := HTTP.Head(Url);
        Stopwatch.Stop;

        if (Response <> nil) and (Response.StatusCode = 200) then
        begin
          if Round(Stopwatch.Elapsed.TotalMilliseconds) < BestPing then
            BestPing := Round(Stopwatch.Elapsed.TotalMilliseconds);
          Result.Status := 'OK';
          Break;
        end;
      except
        // HEAD может быть запрещён — пробуем GET
      end;

      if FCancelled then
        Break;

      try
        Stopwatch := TStopwatch.StartNew;
        Response := HTTP.Get(Url);
        Stopwatch.Stop;

        if (Response <> nil) and (Response.StatusCode = 200) then
        begin
          if Round(Stopwatch.Elapsed.TotalMilliseconds) < BestPing then
            BestPing := Round(Stopwatch.Elapsed.TotalMilliseconds);
          Result.Status := 'OK';
          Break;
        end;
      except
        Continue;
      end;
    end;

    if Result.Status = 'OK' then
      Result.AvgPing := BestPing;
  finally
    HTTP.Free;
  end;
end;

procedure TForm1.UpdateHostsFromMemo;
var
  i: Integer;
  Line: string;
begin
  FHosts.Clear;
  for i := 0 to MemoList.Lines.Count - 1 do
  begin
    Line := Trim(MemoList.Lines[i]);
    if (Line <> '') and (not Line.StartsWith('#')) then
      FHosts.Add(Line);
  end;
  btnStart.Enabled := (FHosts.Count > 0) and (not FIsRunning);
end;

procedure TForm1.MemoListChange(Sender: TObject);
begin
  if not FIsRunning then
    UpdateHostsFromMemo;
end;

procedure TForm1.btnClearListClick(Sender: TObject);
begin
  if FIsRunning then
    Exit;

  MemoList.Lines.Clear;
  MemoLog.Lines.Clear;
  edtURL.Text := 'https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main/whitelist.txt';
  btnStart.Enabled := False;
  ProgressBar1.Value := 0;
  lblStatus.Text := '';
  FHosts.Clear;
end;

procedure TForm1.PasteFromClipboardToMemo;
var
  ClipboardService: IFMXClipboardService;
  ClipboardText: string;
begin
  if TPlatformServices.Current.SupportsPlatformService(IFMXClipboardService, ClipboardService) then
  begin
    ClipboardText := ClipboardService.GetClipboard.ToString;
    if ClipboardText <> '' then
    begin
      MemoList.Lines.Add(ClipboardText);
      UpdateHostsFromMemo;
      ShowToast('Текст вставлен из буфера обмена');
    end
    else
      ShowToast('Буфер обмена пуст');
  end
  else
    ShowToast('Не удалось получить доступ к буферу обмена');
end;

procedure TForm1.btnPasteFromClipboardClick(Sender: TObject);
begin
  if FIsRunning then
  begin
    ShowToast('Дождитесь окончания тестирования');
    Exit;
  end;
  PasteFromClipboardToMemo;
end;

procedure TForm1.LoadWhitelistFromString(const Content: string);
var
  Lines: TStringList;
  i: Integer;
  Count: Integer;
  Temp: TStringList;
begin
  Lines := TStringList.Create;
  Temp := TStringList.Create;
  try
    Lines.Text := Content;
    Count := 0;

    for i := 0 to Lines.Count - 1 do
    begin
      var Line := Trim(Lines[i]);
      if (Line <> '') and (not Line.StartsWith('#')) then
      begin
        Temp.Add(Line);
        Inc(Count);
      end;
    end;

    // ВАЖНО: обращение к Memo — только из главного потока
    TThread.Synchronize(nil,
      procedure
      begin
        MemoList.Lines.BeginUpdate;
        try
          MemoList.Lines.Assign(Temp);
        finally
          MemoList.Lines.EndUpdate;
        end;
        UpdateHostsFromMemo;
      end
    );

    ShowToast(Format('Загружено %d хостов', [Count]));
  finally
    Temp.Free;
    Lines.Free;
  end;
end;

procedure TForm1.LoadWhitelistFromURL(const URL: string);
var
  HTTP: THTTPClient;
  Response: IHTTPResponse;
  Content: string;
begin
  LogMessage('Начало загрузки из URL: ' + URL);

  HTTP := THTTPClient.Create;
  try
    HTTP.ResponseTimeout := 15000;
    HTTP.ConnectionTimeout := 15000;

    try
      Response := HTTP.Get(URL);
      if Response.StatusCode = 200 then
      begin
        Content := Response.ContentAsString;
        LoadWhitelistFromString(Content);
        LogMessage('Список успешно загружен');
      end
      else
      begin
        LogMessage('Ошибка HTTP: ' + Response.StatusCode.ToString);
        ShowToast('Ошибка HTTP: ' + Response.StatusCode.ToString);
      end;
    except
      on E: Exception do
      begin
        LogMessage('Ошибка загрузки: ' + E.Message);
        ShowToast('Ошибка загрузки');
      end;
    end;
  finally
    HTTP.Free;
  end;
end;

procedure TForm1.btnLoadURLClick(Sender: TObject);
var
  Url: string;
begin
  if Trim(edtURL.Text) = '' then
  begin
    ShowToast('Введите URL');
    Exit;
  end;

  if FIsRunning then
  begin
    ShowToast('Дождитесь окончания тестирования');
    Exit;
  end;

  Url := Trim(edtURL.Text);

  TThread.CreateAnonymousThread(
    procedure
    begin
      TThread.Synchronize(nil,
        procedure
        begin
          btnLoadURL.Enabled := False;
          btnLoadURL.Text := 'Загрузка...';
        end
      );

      try
        LoadWhitelistFromURL(Url);
      finally
        TThread.Synchronize(nil,
          procedure
          begin
            btnLoadURL.Enabled := True;
            btnLoadURL.Text := 'Загрузить';
          end
        );
      end;
    end
  ).Start;
end;

procedure TForm1.RunPingTest;
var
  Total, Done, Success: Integer;
  HostsCopy: TArray<string>;
  k: Integer;
begin
  Total := FHosts.Count;
  SetLength(HostsCopy, Total);
  for k := 0 to Total - 1 do
    HostsCopy[k] := FHosts[k];

  // Локальные переменные для потокобезопасных счётчиков
  Done := 0;
  Success := 0;

  TParallel.For(0, Total - 1,
    procedure(i: Integer)
    var
      Res: TPingResult;
      HostCopy: string;
      PingCopy, TimeoutCopy: Integer;
      StatusCopy: string;
      C, S: Integer;
      IsOk: Boolean;
    begin
      if FCancelled then
        Exit;

      HostCopy := HostsCopy[i];
      Res := PingHost(HostCopy);

      PingCopy := Res.AvgPing;
      StatusCopy := Res.Status;
      TimeoutCopy := FTimeoutMs;
      IsOk := (StatusCopy = 'OK');

      // Атомарный инкремент через AtomicIncrement (System.SyncObjs)
      C := AtomicIncrement(Done);
      if IsOk then
        S := AtomicIncrement(Success)
      else
        S := Success;

      // Захватываем ТОЛЬКО локальные копии — это ключ к успеху
      if IsOk then
      begin
        TThread.Queue(nil,
          procedure
          begin
            FCompletedCount := C;
            FSuccessCount := S;
            UpdateProgress;
            LogMessage(Format('✅ %dms - %s', [PingCopy, HostCopy]));
          end
        );
      end
      else
      begin
        TThread.Queue(nil,
          procedure
          begin
            FCompletedCount := C;
            UpdateProgress;
            LogMessage(Format('❌ Таймаут (%dms) - %s', [TimeoutCopy, HostCopy]));
          end
        );
      end;
    end
  );

  TThread.Queue(nil,
    procedure
    begin
      OnPingComplete;
    end
  );
end;

procedure TForm1.ApplyResultsToMemo;
begin
  // Заглушка для возможной сортировки/подсветки, оставлена для расширяемости
end;

procedure TForm1.OnPingComplete;
begin
  LogMessage('========================================');
  LogMessage(Format('Тестирование завершено! Успешно: %d из %d',
    [FSuccessCount, FTotalCount]));
  if FTotalCount > 0 then
    LogMessage(Format('Процент успеха: %.1f%%',
      [(FSuccessCount / FTotalCount) * 100]));
  LogMessage('========================================');

  SetRunningState(False);
  FPingThread := nil;

  if FCancelled then
    ShowToast('Тестирование остановлено')
  else
    ShowToast(Format('Готово! Успешно: %d из %d', [FSuccessCount, FTotalCount]));
end;

procedure TForm1.btnStartClick(Sender: TObject);
begin
  UpdateHostsFromMemo;

  if FHosts.Count = 0 then
  begin
    ShowToast('Список пуст. Загрузите хосты из URL, буфера обмена или введите вручную.');
    Exit;
  end;

  // Единоразово определяем таймаут по галочке (раньше это делалось в каждом PingHost)
  if CheckBox1.IsChecked then
    FTimeoutMs := TIMEOUT_FAST_MS
  else
    FTimeoutMs := TIMEOUT_NORMAL_MS;

  MemoLog.Lines.Clear;
  FCancelled := False;
  FTotalCount := FHosts.Count;
  FCompletedCount := 0;
  FSuccessCount := 0;
  ProgressBar1.Value := 0;
  lblStatus.Text := '';

  SetRunningState(True);

  LogMessage('--- НАЧАЛО ТЕСТИРОВАНИЯ ---');
  LogMessage(Format('Всего хостов: %d, параллельно: %d, таймаут: %d мс',
    [FTotalCount, MAX_PARALLEL_CHECKS, FTimeoutMs]));

  FPingThread := TThread.CreateAnonymousThread(
    procedure
    begin
      // Ограничиваем пул потоков
      TThreadPool.Default.SetMaxWorkerThreads(MAX_PARALLEL_CHECKS);
      try
        RunPingTest;
      except
        on E: Exception do
          LogMessage('Ошибка в RunPingTest: ' + E.Message);
      end;
    end
  );
  FPingThread.FreeOnTerminate := False;
  FPingThread.Start;
end;

procedure TForm1.btnStopClick(Sender: TObject);
begin
  LogMessage('Остановка тестирования...');
  FCancelled := True;
  btnStop.Enabled := False;
  ShowToast('Остановка... (текущие запросы прервутся по таймауту)');
end;

procedure TForm1.edtURLDblClick(Sender: TObject);
begin
  edtURL.Text := '';
end;

end.
