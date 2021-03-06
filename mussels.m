% This script contains an implementation of the code found in
% Coupling freshwater mussel ecology and river dynamics using a simplified dynamic interaction model
% https://doi.org/10.1086/684223

% Copyright (C) 2018 Jon Schwenk
% Developer can be contacted at jonschwenk@gmail.com
% This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.
% This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
% You should have received a copy of the GNU General Public License along with this program; if not, write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

% The script tries to maintain the same naming conventions as those in the
% paper, and is written explicitly and with (unnecessary) intermediate
% variables in effort to make it easier to interpret/modify for those
% unfamiliar with the model. Performance is not an issue; all 12 of our
% study sites can be run over ~4 decades with daily time steps on the 
% order of ~second.

% See the accompanying _readme file for more information about how to run
% or modify the model.

% At the end of this script are commented-out codes for plotting results...

% The model was formulated by all the authors of the referenced paper, but
% implemented and maintained mainly by Jon Schwenk (jonschwenk@gmail.com).
% The version released on CSDMS corresponds to version 8 of our iterations.

% 2/28/2018

clear 
close all
clc

% New site list
% 1. Yellow Bank
% 2. Lac Qui Parle
% 3. Chippewa
% 4. MN-Montevideo
% 5. Redwood-Marshall
% 6. Redwood-R. Falls
% 7. Cottonwood
% 8. Watonwan
% 9. Blue Earth
% 10. Le Sueur
% 11. MN-Jordan
% 12. St. Croix

load MRB_mussel_data.mat % loads observed data, site numbers, dates of val/cal, etc.
load MRB_QS.mat % loads sitenames, Qs, dates, and alphas and betas of flow-sediment and flow-depth relationships

enddates = [MRB_mussels.SiteNo MRB_mussels.model_end_date]; % for running all the way to extent of data (2012 for most sites)
% enddates = [MRB_mussels.SiteNo MRB_mussels.obs_cal_date]; % for testing against optimization end dates
musselweights = MRB_mussels.muss_weight;

sites2run = [3 6 12]; % which sites should be run?
for ii=1:numel(sites2run)
    
    site = sites2run(ii);
    
    %% Assign Q, dates, and alpha/betas for site ii - reading from MRB_QS structure
    alpha_QS = MRB_QS(site).alpha_QS;
    beta_QS = MRB_QS(site).beta_QS;
    alpha_Qd = MRB_QS(site).alpha_Qd;
    beta_Qd = MRB_QS(site).beta_Qd;
    QS_Qmin = MRB_QS(site).QS_Qmin;
    Q = MRB_QS(site).Q;
    dates = MRB_QS(site).dates;

    % adjust dates to model run enddates (maximum of available data)
    dates(dates>enddates(site,2)) = [];

    %% Parameter assignments - regrouped into two groups: parameters that can vary, and those that are fixed
    % Unknown parameters and M(1) (found via optimization) 
    b_M = 4.12*10^-8;
    eps_M = 3.18699*10^-8; % calibrated on 4/9/14 JPS
    M_in_cond = 0.7;    % calibrated on 4/9/14 JPS

    % Known parameters (or parameters for which the model isn't sensitive)
    K_M = 26.2; % carrying capacity, # mussels/area
    b_C = 1.23 * 10^-5; % chlorophyll birth rate
    K_C = 0.4; % carrying capacity, mg/L
    w_M = musselweights(site); % g wet/mussel

    theta_SM = 10; % sediment theshold that modifies birth rate
    theta_SC = 420; 

    SM_max = 50; % Gascho Landis, 2013
    SC_max = 1760; % Stefan et al 1983

    min_eta_SM = 0;
    min_eta_SC = 0;
    min_eta_CM = 0;

    C_rebound = 0.0001; % value to set C if it ever becomes less than zero
    M_rebound = 0.1; % value to set M if it ever becomes less than zero

    %% Model variables
    % prepare flow % L/s
    Q(Q<=0)=1; % L/s; set 0 flow to 1 L/s
    Q=Q(dates>=721964);%9/1/1976
    dates=dates(dates>=721964);%9/1/1976
        
    time_steps = length(Q)-2; % number of time steps to run model 
    dt = diff(dates) * 86400; % time step in seconds
    dt(end) = []; % last dt is garbage

    % Depth approximates hydraulic radius
    R_h = alpha_Qd.*(Q*0.001).^beta_Qd; % m; Q in L/s converted to m3/s for relation (*.001)

    % Initialize variables
    S = NaN(time_steps+1,1);
    M = NaN(time_steps+1,1);
    C = NaN(time_steps+1,1);

    CC1 = NaN(time_steps,1);
    CC2 = NaN(time_steps,1);
    CC = NaN(time_steps,1);
    MC = NaN(time_steps,1);
    QC = NaN(time_steps,1);
    MM = NaN(time_steps,1);
    MS = NaN(time_steps,1);
    QS = NaN(time_steps,1);
    QC = NaN(time_steps,1);
    eta_CM = NaN(time_steps,1);
    eta_SC = NaN(time_steps,1);
    eta_SM = NaN(time_steps,1);
    lambda = NaN(time_steps,1);
    R_c = NaN(time_steps,1);
    phi = NaN(time_steps,1);
    r_M = NaN(time_steps,1);

    % Initial conditions
    S(1) = alpha_QS*Q(1)^beta_QS;% mg/L; Q in L/s, set from flow/SSC relation
    M(1) = M_in_cond; % mussels/m^2
    C(1) = K_C; % mg/L

    %% Run the model
    for t = 1:time_steps-1

      % Lambda
        R_c(t) = -(0.066*exp(-.087*(S(t))))/1000/3600; % best fit of exponential from to values from literature (R2 = 0.58, n = 16, p = 0.0006
        lambda(t) = R_c(t)*w_M/R_h(t); % (m^2)/(#*s)

        % S
        Qcopyt = Q(t);          % these variables are necessary for the stations with breaks in the QS relationship
        Qcopytplus1 = Q(t+1);   % they're just copies of Q(t) and Q(t+1) for computing Psi
        if site == 1 || site == 3  % Chippewa and Yellow Bank have QS thresholds
            Qcopyt = max(QS_Qmin, Qcopyt);
            Qcopytplus1 = max(QS_Qmin, Qcopytplus1);
        end
        
        QS = alpha_QS*(Qcopytplus1^beta_QS - Qcopyt^beta_QS) / dt(t); % mg/L; Q in L/s, flow driving sediment
        MS = S(t)*M(t)*lambda(t); % mussels filtering sediment

        S(t+1) = S(t) + (QS + MS) * dt(t);
        S(t+1) = max(0,S(t+1)); % if S is not produced or all S is filtered out, don't let it become negative

        % M 
        % factor to modify mussel carrying capacity, eta_CM
        if C(t) < K_C
            eta_CM =(0.5/K_C)*C(t) + .5; % eta_s is the M growth rate adjustment due to C   
        else
            eta_CM = 1;
        end
        % eta_SM
        if S(t) > theta_SM
            eta_SM = max(1 - (S(t)-theta_SM)/(SM_max-theta_SM), min_eta_SM); 
        else
            eta_SM=1;
        end
        
        MM1 = (eta_SM * b_M - eps_M) * M(t); % first term of MM equation
        MM2 = 1 - M(t)/(K_M * eta_CM); % second term of MM equation
        if MM1 < 0 && MM2 < 0 % handles cases where r_M is negative and carrying capacity term is also negative--need to check how often this occurs
            MM1 = -MM1;
        end
        MM = MM1 * MM2;

        M(t+1) = M(t) + dt(t) * MM;

        % C
        % eta_SC
        if S(t) > theta_SC   
            eta_SC = max(1 - (S(t)-theta_SC)/(SC_max-theta_SC), min_eta_SC);
        else
            eta_SC = 1;
        end

        CC1(t) = (eta_SC * b_C) * C(t);                 % logistic growth, growth rate
        CC2(t) = 1 - C(t)/K_C;                          % logistic growth, carrying capacity
        CC(t) = CC1(t) * CC2(t);
        MC(t) =  C(t) * M(t) * lambda(t);               % consumption of C by mussels
        QC(t) = C(t) * (1 - Q(t+1) / Q(t)) / dt(t);     % dilution
        % The following line is a central-differencing implementation of 
        % the dilution term; uncomment it and comment the previous line
        % if desired. It produces smoother C(t) but does not appreciably
        % affect M(t) outcomes. You must also change the time steps "for"
        % loop to: t = 2:time_steps-1
%         QC(t) = C(t) * ((Q(t-1) - Q(t+1))/2) / ((Q(t) + Q(t+1))/2) / dt(t);     % dilution
        % For testing strength of QC
%         QC(t) = 0;

        C(t+1) = C(t) + (CC(t) + MC(t) + QC(t)) * dt(t);

        C(t+1) = max(C_rebound,C(t+1)); % Give C a chance to recover if it plummets to zero 
        M(t+1) = max(M_rebound,M(t+1)); % Give M a chance to recover if it plummets to zero

    end % time t

    % Save vars for different runs
    res(ii).name = MRB_QS(site).sitename;
    res(ii).Q = Q;
    res(ii).S = S;
    res(ii).M = M;
    res(ii).C = C;


end % loop through sites

% save('res','res')

% Plot results for a given site
siteno = 1; % Choose site to plot
close all

subplot(4,1,1)
plot(dates,res(siteno).Q)
title(res(siteno).name);
ylabel('Q, L/s')
datetick('x')

subplot(4,1,2)
plot(dates(1:end-1),res(siteno).S,'r')
ylabel('S, mg/L')
datetick('x')

subplot(4,1,3)
plot(dates(1:end-1),res(siteno).C,'g')
ylabel('C, mg/L')
datetick('x')

subplot(4,1,4)
plot(dates(1:end-1),res(siteno).M,'m')
ylabel('M, #/m^2')
datetick('x')

% Code for plotting figures for paper below here. Some variables may not be
% present but can be pulled from the results structure. (e.g. "threesites")

% % %% Calibration values
% % 
% % for k = 1:size(Mpop,2)
% %     if MRB_mussels.obs_cal_date(k) > Mpop(k).dates(end) % the if statement is required because at some sites, calibration dates are beyond the latest date for which data were available (ie not comparing same times)
% %         calidx(k) = numel(Mpop(k).dates);
% %     else
% %         calidx(k) = find(MRB_mussels.obs_cal_date(k)==Mpop(k).dates);
% %     end
% %     obs_values(k,1) = Mpop(k).res(calidx(k));
% % end
% % 
% % clear calidx obs_values
% % %% Fig 7 (revised) - 4/10/2015
% figure(7); clf; hold on
% set(gcf,'Position',[369 49 838 636])
% % sitenos = [3,8,12]; % which sites to plot
% sitenos = [3,8,12]; % which sites to plot
% colors = [
%     0.8203    0.4102    0.1172;
%     0.1172    0.5625    1.0000;
%          0         0    0.5430];    
% for j = 1:3
%     p = sitenos(j);
%     dates = threesites(p).t;
%     Q = threesites(p).Q*1000; % multiply by 1000 to convert to litres
%     C = threesites(p).C;
%     M = threesites(p).M;
%     S = threesites(p).S;
%     c = colors(j,:);
%     time_steps = numel(Q)-1;
% 
%     
%     subplot(4,1,1); hold on
%     plot(dates(1:time_steps),Q(1:time_steps).*0.001,'color',c) %m3/s; converted from L/s
%     datetick('x')
%     if j == 1
%         set(gca,'yscale','log')
%         yt = get(gca,'YTick');
%         ytkvct = 10.^linspace(1,10*size(yt,2),10*size(yt,2));
%         set(gca,'ytick',ytkvct);
%         ylim([10^2 10^6]);
%         ylabel({'Streamflow';'L/s'})
%         set(gca,'tick','out')
%     end
%     xlim([721964 735142])
% 
% 
%     subplot(4,1,2); hold on
%     plot(dates(1:time_steps),S(1:time_steps)*1000,'color',c)
%     datetick('x')
%     if j == 1
%         set(gca,'yscale','log')
%         yt = get(gca,'YTick');
%         ytkvct = 10.^linspace(1,10*size(yt,2),10*size(yt,2));
%         set(gca,'ytick',ytkvct);
%         ylim([10/5 5*10^5]);
%         ylabel({'Susp. Sed. Conc.';'mg/L'})
%         set(gca,'tick','out')
%         set(gca,'yticklabel',[10^-2, 10^-1, 1, 10 100]);
%     end
%     xlim([721964 735142])
% 
% 
%     subplot(4,1,3); hold on
%     plot(dates(1:time_steps),C(1:time_steps),'color',c)
%     datetick('x')
%     ylabel({'Chlorophyll-A Conc.';'mg/L'})
%     ylim([0 0.5])
%     ytixC = .1:.1:.4;
%     set(gca,'tick','out','ytick',ytixC)
%     xlim([721964 735142])
% 
% 
%     subplot(4,1,4); hold on
%     plot(dates(1:time_steps),M(1:time_steps),'color',c) 
%     datetick('x')
%     ylabel({'Mussel Pop.';'#/m^2'})
%     set(gca,'tick','out')
%     xlim([721964 735142])
%     ylim([0 14])
%     legend('Chippewa, 3','Watonwan, 8','St. Croix, 12')
% %     legend('3','4')
% end
% 
% print(gcf,'7_revised','-dpdf');
% 
%  
% %% Fig 8 (revised) - 4/10/2015 
% figure(8); clf;
% 
% % New site list
% % 1. Yellow Bank
% % 2. Lac Qui Parle
% % 3. Chippewa
% % 4. MN-Montevideo
% % 5. Redwood-Marshall
% % 6. Redwood-R. Falls
% % 7. Cottonwood
% % 8. Watonwan
% % 9. Blue Earth
% % 10. Le Sueur
% % 11. MN-Jordan
% % 12. St. Croix
% 
% enddatescal = MRB_mussels.obs_cal_date;
% % enddatescal = MRB_mussels.model_end_date;
% MRB_mussels.obs_val_date = [NaN NaN datenum('7-1-1989') datenum('7-1-1989') NaN NaN NaN NaN NaN NaN datenum('7-1-1989') datenum('1-1-1991')]';
% val_sites = find(isnan(MRB_mussels.obs_val_date)==0);
% enddatesval = [MRB_mussels.SiteNo(val_sites) MRB_mussels.obs_val_date(val_sites)];
% valobs = [MRB_mussels.SiteNo(val_sites) MRB_mussels.obs_val_density(val_sites)];
% 
% obs = MRB_mussels.obs_cal_density;
% 
% plotsites = [1:12];
% 
% colors = [  1     0     0;
%          0.8516    0.6445    0.1250;
%          0    0.5000   0;
%          0     0     1;
%          0.5000         0    0.5000;
%          0     0     0;
%          1.0000    0.2695         0;
%          0.6445    0.1641    0.1641;
%          0    1.0000    0.4961
%          0     1     1;
%          0.7383    0.7148    0.4180;
%          0.5000    0.5000    0.5000;
%          0         0    0.5000;
%          0.8594    0.0781    0.2344;];
% 
% for k = 1:numel(plotsites)
%     if enddatescal(k)-1 > Mpop(k).dates(end)
%         calidx(k) = numel(Mpop(k).dates);
%     else
%         calidx(k) = find(enddatescal(k)-1==Mpop(k).dates);
%     end
% end
% 
% hold on
% for j = 1:numel(plotsites)
%     p = plotsites(j);
%     scatter(enddatescal(p),obs(p),'^','markeredgecolor',colors(p,:),'markerfacecolor',colors(p,:)); % observed
%     text(enddatescal(p)-500,obs(p),num2str(p),'color',colors(p,:)) % labels
%     plot(Mpop(p).dates,Mpop(p).res,'color',colors(p,:)); % population trajectories
%     scatter(enddatescal(p),Mpop(p).res(calidx(p)),'^','markeredgecolor',colors(p,:)); % modeled
%     keepcalvals(j) = Mpop(p).res(calidx(p));
%     keepcalvalsobs(j) = obs(p); 
% end
% 
% for j = 1:numel(valobs)/2
%     p = valobs(j,1);
%     daterow = find(p == enddatesval(:,1));
%     scatter(enddatesval(daterow,2),valobs(j,2),'o', 'markeredgecolor',colors(p,:),'markerfacecolor',colors(p,:)); % observed validation
%     modeldaterow = find(enddatesval(daterow,2) == Mpop(p).dates);
%     scatter(enddatesval(daterow,2),Mpop(p).res(modeldaterow),'o','markeredgecolor',colors(p,:)); % model validation
%     keepvalvals(j) = Mpop(p).res(modeldaterow);
%     keepvalvalsobs(j) = valobs(j,2);
% end
% datetick('x')
% xlabel('year');ylabel('# mussels/m^2')
% set(gca,'tick','out')
% box('off')
% xlim([721964 735142])
% 
% print(gcf,'8_revised','-dpdf');
% 
% 
% %% Figure 5a (revised) - 4/10/2015
% figure(5); clf;
% 
% enddatescal = MRB_mussels.obs_cal_date;
% val_indices = find(isnan(MRB_mussels.obs_val_date)==0);
% enddatesval = [MRB_mussels.SiteNo(val_indices) MRB_mussels.obs_val_date(val_indices)];
% valobs = [MRB_mussels.SiteNo(val_indices) MRB_mussels.obs_val_density(val_indices)];
% obs = MRB_mussels.obs_cal_density;
% 
% plotsites = [1:12];
% for k = 1:numel(plotsites)
%     b = plotsites(k);
%     if enddatescal(b)-1 > Mpop(b).dates
%         calvals(b) = numel(Mpop(b).dates);
%     else
%         calvals(b) = find(enddatescal(b)-1==Mpop(b).dates);
%     end
% end
% 
% hold on
% % Plot 1:1 line
% lims = [0 14];
% xlim(lims); ylim(lims);
% line(lims,lims,'color',[0 0 0],'linewidth',2)
% 
% dx = 0;
% dy = 0;
% % Plot calibration observed versus modeled
% for j = 1:numel(plotsites)
%     p = plotsites(j);
%     scatter(obs(p),Mpop(p).res(calvals(p)),240,'k^','fill');
%     text(obs(p)+dy,Mpop(p).res(calvals(p)),num2str(p),'color','r')
%     calmodel(p) = Mpop(p).res(calvals(p));
% end
% 
% % Plot validation observed versus modeled   
% for j = 1:numel(valobs)/2
%     p = valobs(j,1);
%     daterow = find(p == enddatesval(:,1));
%     modeldaterow = find(enddatesval(daterow,2) == Mpop(p).dates);
%     scatter(valobs(j,2),Mpop(p).res(modeldaterow), 240,'ko','fill')
%     text(valobs(j,2)+dy,Mpop(p).res(modeldaterow),num2str(p),'color','r')
% end
% 
% xlabel('observed, #/m^2');ylabel('modeled, #/m^2')
% set(gca,'tick','out')
% box('off')
% 
% print(gcf,'5a_revised','-dpdf');
% 
